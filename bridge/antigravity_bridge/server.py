"""Pure-stdlib asyncio HTTP/1.1 + RFC 6455 WebSocket server for Antigravity Bridge."""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import logging
import platform
import struct
import time
from dataclasses import dataclass
from typing import Any
from urllib.parse import parse_qs, unquote, urlsplit

from . import API_VERSION
from .approvals import (
    ApprovalAlreadyResolvedError,
    ApprovalManager,
    ApprovalNotFoundError,
    InvalidApprovalDecisionError,
)
from .config import BridgeConfig, verify_token
from .models import ApprovalRequest, BridgeEvent, HostHealth, format_iso_utc, utc_now
from .transcript_store import (
    PathTraversalError,
    ResourceNotFoundError,
    SessionNotFoundError,
    TranscriptStore,
)


LOGGER = logging.getLogger("antigravity_bridge.server")

_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
_MAX_HEADER_BYTES = 65_536
_MAX_BODY_BYTES = 10 * 1024 * 1024
_MAX_WS_FRAME_BYTES = 4 * 1024 * 1024

_STATUS_PHRASES: dict[int, str] = {
    101: "Switching Protocols",
    200: "OK",
    204: "No Content",
    400: "Bad Request",
    401: "Unauthorized",
    403: "Forbidden",
    404: "Not Found",
    405: "Method Not Allowed",
    409: "Conflict",
    413: "Payload Too Large",
    426: "Upgrade Required",
    500: "Internal Server Error",
}


class _HTTPProtocolError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


@dataclass(slots=True)
class HTTPRequest:
    method: str
    raw_target: str
    path: str
    query: dict[str, list[str]]
    http_version: str
    headers: dict[str, str]
    body: bytes

    def query_first(self, name: str, default: str | None = None) -> str | None:
        vals = self.query.get(name)
        if not vals:
            return default
        return vals[0]


class WebSocketConnection:
    """RFC 6455 WebSocket connection wrapper over asyncio streams."""

    def __init__(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        peer: str,
    ) -> None:
        self._reader = reader
        self._writer = writer
        self.peer = peer
        self._write_lock = asyncio.Lock()
        self.closed = False

    async def send_frame(self, opcode: int, payload: bytes = b"") -> None:
        if self.closed:
            return
        length = len(payload)
        header = bytearray()
        header.append(0x80 | (opcode & 0x0F))
        if length < 126:
            header.append(length)
        elif length <= 0xFFFF:
            header.append(126)
            header.extend(struct.pack("!H", length))
        else:
            header.append(127)
            header.extend(struct.pack("!Q", length))

        async with self._write_lock:
            if self.closed:
                return
            try:
                self._writer.write(bytes(header) + payload)
                await self._writer.drain()
            except (ConnectionError, OSError):
                self.closed = True
                raise

    async def send_text(self, text: str) -> None:
        await self.send_frame(0x01, text.encode("utf-8"))

    async def send_json(self, obj: dict[str, Any]) -> None:
        await self.send_text(json.dumps(obj, ensure_ascii=False, separators=(",", ":")))

    async def send_pong(self, payload: bytes = b"") -> None:
        await self.send_frame(0x0A, payload[:125])

    async def send_close(self, code: int = 1000, reason: str = "") -> None:
        if self.closed:
            return
        payload = struct.pack("!H", code) + reason.encode("utf-8")[:123]
        try:
            await self.send_frame(0x08, payload)
        except (ConnectionError, OSError):
            pass
        finally:
            self.closed = True

    async def read_message(self) -> tuple[int, bytes] | None:
        """Read a full (possibly fragmented) WebSocket message; handles Ping/Pong/Close inline."""
        fragments: list[bytes] = []
        message_opcode: int | None = None

        while not self.closed:
            try:
                head = await self._reader.readexactly(2)
            except (asyncio.IncompleteReadError, ConnectionError, OSError):
                self.closed = True
                return None

            b0, b1 = head[0], head[1]
            fin = bool(b0 & 0x80)
            opcode = b0 & 0x0F
            masked = bool(b1 & 0x80)
            length = b1 & 0x7F

            if length == 126:
                ext = await self._reader.readexactly(2)
                (length,) = struct.unpack("!H", ext)
            elif length == 127:
                ext = await self._reader.readexactly(8)
                (length,) = struct.unpack("!Q", ext)

            if length > _MAX_WS_FRAME_BYTES:
                await self.send_close(1009, "Message too big")
                return None

            mask_key = await self._reader.readexactly(4) if masked else b""
            raw_payload = await self._reader.readexactly(length) if length else b""

            if masked and length:
                unmasked = bytearray(raw_payload)
                for i in range(length):
                    unmasked[i] ^= mask_key[i & 3]
                payload = bytes(unmasked)
            else:
                payload = raw_payload

            # Control frames (may be interleaved between fragments per RFC 6455 §5.5)
            if opcode == 0x08:  # Close
                code = struct.unpack("!H", payload[:2])[0] if len(payload) >= 2 else 1000
                await self.send_close(code)
                return None
            if opcode == 0x09:  # Ping
                await self.send_pong(payload)
                continue
            if opcode == 0x0A:  # Pong
                continue

            if opcode in (0x01, 0x02):
                message_opcode = opcode
                fragments = [payload]
            elif opcode == 0x00:
                if message_opcode is None:
                    await self.send_close(1002, "Unexpected continuation frame")
                    return None
                fragments.append(payload)
            else:
                await self.send_close(1002, "Unsupported opcode")
                return None

            if fin and message_opcode is not None:
                return message_opcode, b"".join(fragments)

        return None


def _parse_bool_param(raw: str | None, default: bool = False) -> bool:
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def _parse_int_param(raw: str | None, default: int, *, minimum: int = 0, maximum: int = 10_000) -> int:
    if raw is None:
        return default
    try:
        val = int(raw.strip())
    except ValueError:
        return default
    return max(minimum, min(maximum, val))


class BridgeServer:
    """Async HTTP/1.1 + WebSocket companion bridge server for Antigravity 2.0."""

    def __init__(
        self,
        config: BridgeConfig,
        *,
        store: TranscriptStore | None = None,
        approvals: ApprovalManager | None = None,
    ) -> None:
        self.config = config
        self.store = store or TranscriptStore(
            config.brain_dir,
            active_threshold_seconds=config.active_threshold_seconds,
        )
        self.approvals = approvals or ApprovalManager()
        self.approvals.set_callbacks(
            on_requested=self._on_approval_requested,
            on_resolved=self._on_approval_resolved,
        )

        self._started_monotonic = time.monotonic()
        self._server: asyncio.AbstractServer | None = None
        self._ws_clients: set[WebSocketConnection] = set()
        self._hook_status_hints: dict[str, str] = {}
        self._bound_port: int = config.port

    @property
    def bound_port(self) -> int:
        return self._bound_port

    @property
    def ws_client_count(self) -> int:
        return len(self._ws_clients)

    def hook_status_hints(self) -> dict[str, str]:
        return dict(self._hook_status_hints)

    def get_health(self) -> HostHealth:
        """Compute current HostHealth snapshot."""
        pending_ids = self.approvals.pending_session_ids()
        sessions = self.store.list_sessions(
            limit=0,
            pending_session_ids=pending_ids,
            hook_status_hints=self._hook_status_hints,
        )
        active_count = sum(1 for s in sessions if s.status in ("running", "waiting"))
        total_in = sum(s.input_tokens for s in sessions)
        total_cache = sum(s.cache_read_tokens for s in sessions)
        total_out = sum(s.output_tokens for s in sessions)

        return HostHealth(
            status="ok",
            api_version=API_VERSION,
            hostname=self.config.host_name,
            platform=f"{platform.system()} {platform.release()} ({platform.machine()})",
            uptime_seconds=int(time.monotonic() - self._started_monotonic),
            brain_dir=str(self.store.brain_dir),
            brain_dir_exists=self.store.brain_dir_exists(),
            session_count=len(sessions),
            active_session_count=active_count,
            pending_approval_count=self.approvals.pending_count(),
            total_input_tokens=total_in,
            total_cache_read_tokens=total_cache,
            total_output_tokens=total_out,
            server_time=format_iso_utc(utc_now()),
        )

    async def start(self) -> None:
        """Start listening for incoming TCP connections."""
        if self._server is not None:
            return
        self._started_monotonic = time.monotonic()
        self._server = await asyncio.start_server(
            self._handle_client,
            host=self.config.host,
            port=self.config.port,
        )
        sockets = self._server.sockets or []
        if sockets:
            self._bound_port = sockets[0].getsockname()[1]
        LOGGER.info(
            "Antigravity Bridge listening on %s:%d (brain_dir=%s)",
            self.config.host,
            self._bound_port,
            self.store.brain_dir,
        )

    async def stop(self) -> None:
        """Stop accepting connections, resolve pending approvals, and close WebSockets."""
        await self.approvals.cancel_all()

        clients = list(self._ws_clients)
        self._ws_clients.clear()
        for ws in clients:
            try:
                await ws.send_close(1001, "Server shutting down")
            except Exception:
                pass

        if self._server is not None:
            self._server.close()
            try:
                await self._server.wait_closed()
            except Exception:
                pass
            self._server = None

    async def broadcast_event(self, event: BridgeEvent) -> None:
        """Broadcast a BridgeEvent JSON envelope to all connected WebSocket clients."""
        if not self._ws_clients:
            return
        payload = json.dumps(event.to_dict(), ensure_ascii=False, separators=(",", ":"))
        dead: list[WebSocketConnection] = []
        for ws in list(self._ws_clients):
            try:
                await ws.send_text(payload)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self._ws_clients.discard(ws)

    async def _on_approval_requested(self, approval: ApprovalRequest) -> None:
        await self.broadcast_event(
            BridgeEvent(
                type="approval_requested",
                timestamp=format_iso_utc(utc_now()),
                session_id=approval.session_id,
                approval=approval,
                message=approval.summary,
            )
        )

    async def _on_approval_resolved(self, approval: ApprovalRequest) -> None:
        await self.broadcast_event(
            BridgeEvent(
                type="approval_resolved",
                timestamp=format_iso_utc(utc_now()),
                session_id=approval.session_id,
                approval=approval,
                message=approval.decision_reason or f"Approval {approval.status}",
            )
        )

    def _extract_bearer_token(self, headers: dict[str, str]) -> str | None:
        auth = headers.get("authorization", "").strip()
        if not auth:
            return None
        parts = auth.split(None, 1)
        if len(parts) != 2 or parts[0].lower() != "bearer":
            return None
        return parts[1].strip()

    def _is_authenticated_rest(self, req: HTTPRequest) -> bool:
        return verify_token(self._extract_bearer_token(req.headers), self.config.token)

    def _is_authenticated_ws(self, req: HTTPRequest) -> bool:
        header_token = self._extract_bearer_token(req.headers)
        if verify_token(header_token, self.config.token):
            return True
        query_token = req.query_first("token")
        return verify_token(query_token, self.config.token)

    async def _read_http_request(self, reader: asyncio.StreamReader) -> HTTPRequest | None:
        try:
            raw_head = await reader.readuntil(b"\r\n\r\n")
        except asyncio.IncompleteReadError as exc:
            if not exc.partial:
                return None
            raise _HTTPProtocolError(400, "Incomplete HTTP request.") from exc
        except asyncio.LimitOverrunError as exc:
            raise _HTTPProtocolError(413, "HTTP headers too large.") from exc
        except (ConnectionError, OSError):
            return None

        if len(raw_head) > _MAX_HEADER_BYTES:
            raise _HTTPProtocolError(413, "HTTP headers too large.")

        header_text = raw_head[:-4].decode("iso-8859-1")
        lines = header_text.split("\r\n")
        if not lines:
            raise _HTTPProtocolError(400, "Empty HTTP request.")

        req_parts = lines[0].split(" ")
        if len(req_parts) != 3:
            raise _HTTPProtocolError(400, "Malformed HTTP request line.")
        method, raw_target, http_version = req_parts[0].upper(), req_parts[1], req_parts[2]

        headers: dict[str, str] = {}
        for line in lines[1:]:
            if not line or ":" not in line:
                continue
            name, value = line.split(":", 1)
            key = name.strip().lower()
            val = value.strip()
            if key in headers:
                headers[key] = f"{headers[key]}, {val}"
            else:
                headers[key] = val

        body = b""
        transfer_encoding = headers.get("transfer-encoding", "").lower()
        if "chunked" in transfer_encoding:
            chunks: list[bytes] = []
            total = 0
            while True:
                size_line = await reader.readline()
                if not size_line:
                    raise _HTTPProtocolError(400, "Incomplete chunked body.")
                size_str = size_line.split(b";", 1)[0].strip()
                try:
                    chunk_size = int(size_str, 16)
                except ValueError as exc:
                    raise _HTTPProtocolError(400, "Invalid chunk size.") from exc
                if chunk_size == 0:
                    # Consume trailing CRLF after 0-length chunk
                    await reader.readline()
                    break
                total += chunk_size
                if total > _MAX_BODY_BYTES:
                    raise _HTTPProtocolError(413, "Request body too large.")
                chunk_data = await reader.readexactly(chunk_size)
                chunks.append(chunk_data)
                await reader.readexactly(2)  # trailing CRLF
            body = b"".join(chunks)
        elif "content-length" in headers:
            try:
                content_length = int(headers["content-length"])
            except ValueError as exc:
                raise _HTTPProtocolError(400, "Invalid Content-Length.") from exc
            if content_length < 0:
                raise _HTTPProtocolError(400, "Negative Content-Length.")
            if content_length > _MAX_BODY_BYTES:
                raise _HTTPProtocolError(413, "Request body too large.")
            if content_length > 0:
                try:
                    body = await reader.readexactly(content_length)
                except asyncio.IncompleteReadError as exc:
                    raise _HTTPProtocolError(400, "Incomplete request body.") from exc

        split = urlsplit(raw_target)
        query = parse_qs(split.query, keep_blank_values=True)
        return HTTPRequest(
            method=method,
            raw_target=raw_target,
            path=split.path,
            query=query,
            http_version=http_version,
            headers=headers,
            body=body,
        )

    async def _send_response(
        self,
        writer: asyncio.StreamWriter,
        status: int,
        body: bytes,
        *,
        content_type: str = "application/json; charset=utf-8",
        extra_headers: dict[str, str] | None = None,
        keep_alive: bool = False,
        head_only: bool = False,
    ) -> None:
        phrase = _STATUS_PHRASES.get(status, "OK")
        headers: dict[str, str] = {
            "Server": f"AntigravityBridge/{API_VERSION}",
            "Content-Type": content_type,
            "Content-Length": str(len(body)),
            "Cache-Control": "no-store",
            "Connection": "keep-alive" if keep_alive else "close",
        }
        if extra_headers:
            headers.update(extra_headers)

        lines = [f"HTTP/1.1 {status} {phrase}"]
        for k, v in headers.items():
            lines.append(f"{k}: {v}")
        raw_head = ("\r\n".join(lines) + "\r\n\r\n").encode("iso-8859-1")
        writer.write(raw_head if head_only else raw_head + body)
        await writer.drain()

    async def _send_json(
        self,
        writer: asyncio.StreamWriter,
        status: int,
        payload: dict[str, Any],
        *,
        extra_headers: dict[str, str] | None = None,
        keep_alive: bool = False,
        head_only: bool = False,
    ) -> None:
        raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        await self._send_response(
            writer,
            status,
            raw,
            content_type="application/json; charset=utf-8",
            extra_headers=extra_headers,
            keep_alive=keep_alive,
            head_only=head_only,
        )

    async def _handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        peer_info = writer.get_extra_info("peername")
        peer = f"{peer_info[0]}:{peer_info[1]}" if isinstance(peer_info, tuple) and len(peer_info) >= 2 else str(peer_info)

        try:
            while True:
                try:
                    req = await self._read_http_request(reader)
                except _HTTPProtocolError as exc:
                    await self._send_json(writer, exc.status, {"error": exc.message}, keep_alive=False)
                    return

                if req is None:
                    return

                conn_hdr = req.headers.get("connection", "").lower()
                if req.http_version == "HTTP/1.0":
                    keep_alive = "keep-alive" in conn_hdr
                else:
                    keep_alive = "close" not in conn_hdr

                # WebSocket upgrade endpoint
                if req.path == "/api/v1/ws":
                    await self._handle_websocket(req, reader, writer, peer)
                    return

                await self._dispatch_http(req, writer, keep_alive=keep_alive)
                if not keep_alive:
                    return
        except (ConnectionError, OSError, asyncio.CancelledError):
            pass
        except Exception:
            LOGGER.exception("Unhandled error serving client %s", peer)
            try:
                await self._send_json(writer, 500, {"error": "Internal server error"}, keep_alive=False)
            except Exception:
                pass
        finally:
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass

    async def _handle_websocket(
        self,
        req: HTTPRequest,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        peer: str,
    ) -> None:
        if req.method != "GET":
            await self._send_json(writer, 405, {"error": "Method not allowed"}, keep_alive=False)
            return

        if not self._is_authenticated_ws(req):
            await self._send_json(
                writer,
                401,
                {"error": "Unauthorized"},
                extra_headers={"WWW-Authenticate": "Bearer"},
                keep_alive=False,
            )
            return

        upgrade = req.headers.get("upgrade", "").lower()
        connection = req.headers.get("connection", "").lower()
        ws_key = req.headers.get("sec-websocket-key", "").strip()
        if upgrade != "websocket" or "upgrade" not in connection or not ws_key:
            await self._send_json(
                writer,
                426,
                {"error": "Expected WebSocket upgrade handshake"},
                extra_headers={"Upgrade": "websocket"},
                keep_alive=False,
            )
            return

        accept_digest = hashlib.sha1((ws_key + _WS_GUID).encode("ascii")).digest()
        accept_val = base64.b64encode(accept_digest).decode("ascii")
        handshake = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept_val}\r\n"
            "\r\n"
        ).encode("iso-8859-1")
        writer.write(handshake)
        await writer.drain()

        ws = WebSocketConnection(reader, writer, peer)
        self._ws_clients.add(ws)
        try:
            health = await asyncio.to_thread(self.get_health)
            hello = BridgeEvent(
                type="hello",
                timestamp=format_iso_utc(utc_now()),
                message="Connected to Antigravity Bridge",
                health=health,
            )
            await ws.send_json(hello.to_dict())

            while not ws.closed:
                msg = await ws.read_message()
                if msg is None:
                    break
                opcode, payload = msg
                if opcode != 0x01:
                    continue
                try:
                    data = json.loads(payload.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    continue
                if isinstance(data, dict) and data.get("type") == "ping":
                    pong = BridgeEvent(
                        type="pong",
                        timestamp=format_iso_utc(utc_now()),
                    )
                    await ws.send_json(pong.to_dict())
        finally:
            self._ws_clients.discard(ws)

    def _parse_json_body(self, req: HTTPRequest) -> dict[str, Any]:
        if not req.body:
            return {}
        try:
            parsed = json.loads(req.body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise _HTTPProtocolError(400, "Invalid JSON request body.") from exc
        if not isinstance(parsed, dict):
            raise _HTTPProtocolError(400, "JSON body must be an object.")
        return parsed

    async def _dispatch_http(
        self,
        req: HTTPRequest,
        writer: asyncio.StreamWriter,
        *,
        keep_alive: bool,
    ) -> None:
        method = req.method
        head_only = method == "HEAD"
        effective_method = "GET" if head_only else method
        path = req.path

        # 1. GET /api/v1/ping (unauthenticated)
        if path == "/api/v1/ping":
            if effective_method != "GET":
                await self._send_json(writer, 405, {"error": "Method not allowed"}, keep_alive=keep_alive)
                return
            await self._send_json(
                writer,
                200,
                {"ok": True, "api_version": API_VERSION},
                keep_alive=keep_alive,
                head_only=head_only,
            )
            return

        if not path.startswith("/api/v1/"):
            await self._send_json(writer, 404, {"error": "Not found"}, keep_alive=keep_alive)
            return

        # All other /api/v1/* endpoints require Bearer authentication
        if not self._is_authenticated_rest(req):
            await self._send_json(
                writer,
                401,
                {"error": "Unauthorized"},
                extra_headers={"WWW-Authenticate": "Bearer"},
                keep_alive=keep_alive,
            )
            return

        try:
            # 2. GET /api/v1/health
            if path == "/api/v1/health":
                if effective_method != "GET":
                    await self._send_json(writer, 405, {"error": "Method not allowed"}, keep_alive=keep_alive)
                    return
                health = await asyncio.to_thread(self.get_health)
                await self._send_json(writer, 200, health.to_dict(), keep_alive=keep_alive, head_only=head_only)
                return

            # 3. GET /api/v1/sessions
            if path == "/api/v1/sessions":
                if effective_method != "GET":
                    await self._send_json(writer, 405, {"error": "Method not allowed"}, keep_alive=keep_alive)
                    return
                limit = _parse_int_param(req.query_first("limit"), 50, minimum=1, maximum=500)
                pending_ids = self.approvals.pending_session_ids()
                sessions = await asyncio.to_thread(
                    self.store.list_sessions,
                    limit=limit,
                    pending_session_ids=pending_ids,
                    hook_status_hints=self._hook_status_hints,
                )
                await self._send_json(
                    writer,
                    200,
                    {"sessions": [s.to_dict() for s in sessions]},
                    keep_alive=keep_alive,
                    head_only=head_only,
                )
                return

            # 4-8. /api/v1/sessions/{session_id}/...
            if path.startswith("/api/v1/sessions/"):
                await self._dispatch_session_route(req, effective_method, writer, keep_alive=keep_alive, head_only=head_only)
                return

            # 9. GET /api/v1/approvals
            if path == "/api/v1/approvals":
                if effective_method != "GET":
                    await self._send_json(writer, 405, {"error": "Method not allowed"}, keep_alive=keep_alive)
                    return
                items = self.approvals.list_approvals()
                await self._send_json(
                    writer,
                    200,
                    {"approvals": [a.to_dict() for a in items]},
                    keep_alive=keep_alive,
                    head_only=head_only,
                )
                return

            # 10. POST /api/v1/approvals/request
            if path == "/api/v1/approvals/request":
                if effective_method != "POST":
                    await self._send_json(writer, 405, {"error": "Method not allowed"}, keep_alive=keep_alive)
                    return
                body = self._parse_json_body(req)
                tool_name = body.get("tool_name")
                if not isinstance(tool_name, str) or not tool_name.strip():
                    raise _HTTPProtocolError(400, "Missing required string field 'tool_name'.")
                args = body.get("args")
                if args is not None and not isinstance(args, dict):
                    raise _HTTPProtocolError(400, "Field 'args' must be a JSON object.")
                session_id = body.get("session_id")
                if session_id is not None and not isinstance(session_id, str):
                    session_id = str(session_id)
                hook_event = str(body.get("hook_event") or "PreToolUse")
                summary = body.get("summary")
                if summary is not None and not isinstance(summary, str):
                    summary = str(summary)
                timeout_raw = body.get("timeout_seconds", 55)
                try:
                    timeout_seconds = float(timeout_raw)
                except (TypeError, ValueError) as exc:
                    raise _HTTPProtocolError(400, "Invalid 'timeout_seconds'.") from exc
                default_decision = str(body.get("default_decision") or "deny")

                resolved = await self.approvals.request_approval(
                    tool_name=tool_name.strip(),
                    args=args or {},
                    session_id=session_id,
                    hook_event=hook_event,
                    summary=summary,
                    timeout_seconds=timeout_seconds,
                    default_decision=default_decision,
                )
                await self._send_json(
                    writer,
                    200,
                    {
                        "id": resolved.id,
                        "decision": resolved.decision or default_decision,
                        "reason": resolved.decision_reason or "",
                        "status": resolved.status,
                    },
                    keep_alive=keep_alive,
                )
                return

            # 11. POST /api/v1/approvals/{approval_id}/decide
            if path.startswith("/api/v1/approvals/") and path.endswith("/decide"):
                if effective_method != "POST":
                    await self._send_json(writer, 405, {"error": "Method not allowed"}, keep_alive=keep_alive)
                    return
                approval_id = unquote(path[len("/api/v1/approvals/") : -len("/decide")])
                if not approval_id or "/" in approval_id:
                    await self._send_json(writer, 404, {"error": "Approval not found"}, keep_alive=keep_alive)
                    return
                body = self._parse_json_body(req)
                decision = body.get("decision")
                if not isinstance(decision, str):
                    raise _HTTPProtocolError(400, "Missing required string field 'decision'.")
                reason = body.get("reason")
                if reason is not None and not isinstance(reason, str):
                    reason = str(reason)
                updated = await self.approvals.decide(
                    approval_id,
                    decision=decision,
                    reason=reason,
                )
                await self._send_json(writer, 200, updated.to_dict(), keep_alive=keep_alive)
                return

            # 12. POST /api/v1/hooks/event
            if path == "/api/v1/hooks/event":
                if effective_method != "POST":
                    await self._send_json(writer, 405, {"error": "Method not allowed"}, keep_alive=keep_alive)
                    return
                body = self._parse_json_body(req)
                event_name = body.get("event")
                if not isinstance(event_name, str) or not event_name.strip():
                    raise _HTTPProtocolError(400, "Missing required string field 'event'.")
                event_name = event_name.strip()
                session_id = body.get("session_id")
                if session_id is not None:
                    session_id = str(session_id)
                tool_name = body.get("tool_name")
                summary = body.get("summary")
                message = (
                    str(summary)
                    if summary
                    else (f"{event_name}: {tool_name}" if tool_name else event_name)
                )

                if session_id:
                    if event_name == "Stop":
                        self._hook_status_hints[session_id] = "completed"
                    elif event_name in ("PreInvocation", "PreToolUse", "PostToolUse", "SessionStart"):
                        self._hook_status_hints[session_id] = "running"

                await self.broadcast_event(
                    BridgeEvent(
                        type="hook_event",
                        timestamp=format_iso_utc(utc_now()),
                        session_id=session_id,
                        hook_event_name=event_name,
                        message=message,
                    )
                )
                await self._send_json(writer, 200, {"ok": True}, keep_alive=keep_alive)
                return

            await self._send_json(writer, 404, {"error": "Not found"}, keep_alive=keep_alive)
        except _HTTPProtocolError as exc:
            await self._send_json(writer, exc.status, {"error": exc.message}, keep_alive=keep_alive)
        except PathTraversalError as exc:
            await self._send_json(writer, 403, {"error": str(exc)}, keep_alive=keep_alive)
        except (SessionNotFoundError, ResourceNotFoundError, ApprovalNotFoundError) as exc:
            await self._send_json(writer, 404, {"error": str(exc)}, keep_alive=keep_alive)
        except ApprovalAlreadyResolvedError as exc:
            await self._send_json(writer, 409, {"error": str(exc)}, keep_alive=keep_alive)
        except InvalidApprovalDecisionError as exc:
            await self._send_json(writer, 400, {"error": str(exc)}, keep_alive=keep_alive)

    async def _dispatch_session_route(
        self,
        req: HTTPRequest,
        effective_method: str,
        writer: asyncio.StreamWriter,
        *,
        keep_alive: bool,
        head_only: bool,
    ) -> None:
        if effective_method != "GET":
            await self._send_json(writer, 405, {"error": "Method not allowed"}, keep_alive=keep_alive)
            return

        remainder = req.path[len("/api/v1/sessions/") :]
        parts = remainder.split("/", 2)
        if len(parts) < 2:
            await self._send_json(writer, 404, {"error": "Not found"}, keep_alive=keep_alive)
            return

        raw_session_id = parts[0]
        session_id = unquote(raw_session_id)
        resource = parts[1]
        tail = parts[2] if len(parts) == 3 else ""

        # 4. GET /api/v1/sessions/{session_id}/transcript
        if resource == "transcript" and not tail:
            since_step = _parse_int_param(req.query_first("since_step"), 0, minimum=0, maximum=1_000_000)
            limit = _parse_int_param(req.query_first("limit"), 200, minimum=1, maximum=2000)
            full = _parse_bool_param(req.query_first("full"), default=False)
            total_steps, steps = await asyncio.to_thread(
                self.store.get_transcript,
                session_id,
                since_step=since_step,
                limit=limit,
                full=full,
            )
            await self._send_json(
                writer,
                200,
                {
                    "session_id": session_id,
                    "total_steps": total_steps,
                    "steps": [s.to_dict() for s in steps],
                },
                keep_alive=keep_alive,
                head_only=head_only,
            )
            return

        # 5. GET /api/v1/sessions/{session_id}/artifacts
        if resource == "artifacts" and not tail:
            artifacts = await asyncio.to_thread(self.store.list_artifacts, session_id)
            await self._send_json(
                writer,
                200,
                {
                    "session_id": session_id,
                    "artifacts": [a.to_dict() for a in artifacts],
                },
                keep_alive=keep_alive,
                head_only=head_only,
            )
            return

        # 6. GET /api/v1/sessions/{session_id}/artifacts/{path}
        if resource == "artifacts" and tail:
            decoded_rel = unquote(tail)
            name, rel_path, mime_type, raw_bytes = await asyncio.to_thread(
                self.store.read_artifact,
                session_id,
                decoded_rel,
            )
            fmt = (req.query_first("format") or "").strip().lower()
            if fmt == "json":
                if mime_type.startswith("image/") and mime_type != "image/svg+xml":
                    content_str = base64.b64encode(raw_bytes).decode("ascii")
                else:
                    content_str = raw_bytes.decode("utf-8", errors="replace")
                await self._send_json(
                    writer,
                    200,
                    {
                        "name": name,
                        "relative_path": rel_path,
                        "mime_type": mime_type,
                        "content": content_str,
                    },
                    keep_alive=keep_alive,
                    head_only=head_only,
                )
            else:
                await self._send_response(
                    writer,
                    200,
                    raw_bytes,
                    content_type=mime_type,
                    keep_alive=keep_alive,
                    head_only=head_only,
                )
            return

        # 7. GET /api/v1/sessions/{session_id}/tasks
        if resource == "tasks" and not tail:
            tasks, subagents, swarm_events = await asyncio.to_thread(self.store.get_session_tasks, session_id)
            await self._send_json(
                writer,
                200,
                {
                    "session_id": session_id,
                    "tasks": [t.to_dict() for t in tasks],
                    "subagents": [sa.to_dict() for sa in subagents],
                    "swarm_events": [se.to_dict() for se in swarm_events],
                },
                keep_alive=keep_alive,
                head_only=head_only,
            )
            return

        # 8. GET /api/v1/sessions/{session_id}/media/{filename}
        if resource == "media" and tail:
            decoded_filename = unquote(tail)
            mime_type, raw_bytes = await asyncio.to_thread(
                self.store.read_media,
                session_id,
                decoded_filename,
            )
            await self._send_response(
                writer,
                200,
                raw_bytes,
                content_type=mime_type,
                keep_alive=keep_alive,
                head_only=head_only,
            )
            return

        await self._send_json(writer, 404, {"error": "Not found"}, keep_alive=keep_alive)
