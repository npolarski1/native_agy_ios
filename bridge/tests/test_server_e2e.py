"""End-to-end loopback TCP tests for BridgeServer REST, RFC 6455 WebSocket, hooks, and CLI."""

from __future__ import annotations

import asyncio
import base64
import contextlib
import hashlib
import io
import json
import os
import secrets
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from urllib.error import HTTPError
from urllib.request import Request, urlopen

_BRIDGE_ROOT = str(Path(__file__).resolve().parent.parent)
if _BRIDGE_ROOT not in sys.path:
    sys.path.insert(0, _BRIDGE_ROOT)

from antigravity_bridge.__main__ import main as cli_main
from antigravity_bridge.config import BridgeConfig
from antigravity_bridge.server import BridgeServer
from antigravity_bridge.watcher import BrainWatcher


_HOOK_SCRIPT = Path(_BRIDGE_ROOT) / "hooks" / "antigravity_hook.py"


class _TestWSClient:
    """Minimal stdlib RFC 6455 WebSocket client for end-to-end loopback testing."""

    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.reader = reader
        self.writer = writer

    @classmethod
    async def connect(
        cls,
        host: str,
        port: int,
        path: str,
        *,
        headers: dict[str, str] | None = None,
    ) -> tuple[int, dict[str, str], _TestWSClient | None]:
        reader, writer = await asyncio.open_connection(host, port)
        ws_key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
        req_headers = {
            "Host": f"{host}:{port}",
            "Upgrade": "websocket",
            "Connection": "Upgrade",
            "Sec-WebSocket-Key": ws_key,
            "Sec-WebSocket-Version": "13",
        }
        if headers:
            req_headers.update(headers)

        lines = [f"GET {path} HTTP/1.1"] + [f"{k}: {v}" for k, v in req_headers.items()]
        writer.write(("\r\n".join(lines) + "\r\n\r\n").encode("iso-8859-1"))
        await writer.drain()

        raw_head = await reader.readuntil(b"\r\n\r\n")
        head_lines = raw_head[:-4].decode("iso-8859-1").split("\r\n")
        status = int(head_lines[0].split(" ")[1])
        resp_headers: dict[str, str] = {}
        for line in head_lines[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                resp_headers[k.strip().lower()] = v.strip()

        if status != 101:
            writer.close()
            await writer.wait_closed()
            return status, resp_headers, None

        expected_accept = base64.b64encode(
            hashlib.sha1((ws_key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
        ).decode("ascii")
        assert resp_headers.get("sec-websocket-accept") == expected_accept
        return status, resp_headers, cls(reader, writer)

    async def send_frame(self, opcode: int, payload: bytes) -> None:
        mask = secrets.token_bytes(4)
        length = len(payload)
        header = bytearray([0x80 | opcode])
        if length < 126:
            header.append(0x80 | length)
        elif length <= 0xFFFF:
            header.append(0x80 | 126)
            header.extend(struct.pack("!H", length))
        else:
            header.append(0x80 | 127)
            header.extend(struct.pack("!Q", length))
        masked = bytes(b ^ mask[i & 3] for i, b in enumerate(payload))
        self.writer.write(bytes(header) + mask + masked)
        await self.writer.drain()

    async def send_json(self, obj: dict[str, Any]) -> None:
        await self.send_frame(0x01, json.dumps(obj).encode("utf-8"))

    async def recv_frame(self, timeout: float = 5.0) -> tuple[int, bytes]:
        head = await asyncio.wait_for(self.reader.readexactly(2), timeout=timeout)
        opcode = head[0] & 0x0F
        masked = bool(head[1] & 0x80)
        assert not masked, "Server->Client frames must not be masked per RFC 6455"
        length = head[1] & 0x7F
        if length == 126:
            (length,) = struct.unpack("!H", await asyncio.wait_for(self.reader.readexactly(2), timeout=timeout))
        elif length == 127:
            (length,) = struct.unpack("!Q", await asyncio.wait_for(self.reader.readexactly(8), timeout=timeout))
        payload = await asyncio.wait_for(self.reader.readexactly(length), timeout=timeout) if length else b""
        return opcode, payload

    async def recv_json(self, timeout: float = 5.0) -> dict[str, Any]:
        opcode, payload = await self.recv_frame(timeout=timeout)
        assert opcode == 0x01
        return json.loads(payload.decode("utf-8"))

    async def recv_until_type(self, expected_type: str, *, max_events: int = 10, timeout: float = 5.0) -> dict[str, Any]:
        seen: list[str] = []
        for _ in range(max_events):
            ev = await self.recv_json(timeout=timeout)
            ev_type = str(ev.get("type"))
            seen.append(ev_type)
            if ev_type == expected_type:
                return ev
        raise AssertionError(f"Did not receive '{expected_type}'; saw {seen}")

    async def close(self) -> None:
        try:
            await self.send_frame(0x08, struct.pack("!H", 1000))
        except Exception:
            pass
        try:
            self.writer.close()
            await self.writer.wait_closed()
        except Exception:
            pass


class BridgeServerE2ETests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.brain_dir = self.root / "brain"
        self.config_dir = self.root / "config"
        self.brain_dir.mkdir(parents=True, exist_ok=True)
        self.config_dir.mkdir(parents=True, exist_ok=True)
        self.token = "test-bearer-token-e2e-xyz123"

        # Seed one session
        self.session_id = "sess-alpha"
        sdir = self.brain_dir / self.session_id
        logs = sdir / ".system_generated" / "logs"
        tasks = sdir / ".system_generated" / "tasks"
        media = sdir / ".system_generated" / "media"
        logs.mkdir(parents=True, exist_ok=True)
        tasks.mkdir(parents=True, exist_ok=True)
        media.mkdir(parents=True, exist_ok=True)

        self.transcript_path = logs / "transcript.jsonl"
        self.transcript_full_path = logs / "transcript_full.jsonl"
        step0 = {
            "step_index": 0,
            "source": "USER_EXPLICIT",
            "type": "USER_INPUT",
            "status": "DONE",
            "created_at": "2026-11-20T20:30:00Z",
            "content": "Ship the native iOS Antigravity Monitor",
        }
        step1 = {
            "step_index": 1,
            "source": "MODEL",
            "type": "PLANNER_RESPONSE",
            "status": "DONE",
            "created_at": "2026-11-20T20:30:05Z",
            "model": "gemini-3-pro",
            "input_tokens": 500,
            "cache_read_tokens": 200,
            "output_tokens": 100,
            "content": "Short summary",
            "truncated_fields": ["content"],
            "tool_calls": [
                {"name": "swarm", "args": {"action": "title", "title": "Native iOS Monitor"}},
            ],
            "media": [{"mime_type": "image/png", "uri": str(media / "preview.png")}],
        }
        self.transcript_path.write_text(
            json.dumps(step0) + "\n" + json.dumps(step1) + "\n",
            encoding="utf-8",
        )
        self.transcript_full_path.write_text(
            json.dumps(step0)
            + "\n"
            + json.dumps({**step1, "content": "Full detailed summary", "truncated_fields": []})
            + "\n",
            encoding="utf-8",
        )
        (media / "preview.png").write_bytes(b"\x89PNG\r\n\x1a\nPREVIEW")
        (sdir / "report.md").write_text("# Status Report\n\nEverything green.\n", encoding="utf-8")
        (tasks / "build-1.log").write_text("compiling...\nbuild succeeded\n", encoding="utf-8")
        (self.root / "outside.txt").write_text("SECRET_OUTSIDE", encoding="utf-8")

        self.config = BridgeConfig(
            host="127.0.0.1",
            port=0,
            token=self.token,
            brain_dir=self.brain_dir,
            config_dir=self.config_dir,
            host_name="TestWorkstation",
            poll_interval=0.05,
            health_tick_interval=60.0,
            enable_bonjour=False,
        )
        self.server = BridgeServer(self.config)
        self.watcher = BrainWatcher(
            self.server.store,
            self.server.broadcast_event,
            self.server.get_health,
            pending_session_ids_provider=self.server.approvals.pending_session_ids,
            hook_hints_provider=self.server.hook_status_hints,
            poll_interval=0.05,
            health_tick_interval=60.0,
        )
        await self.server.start()
        self.config.port = self.server.bound_port
        self.config.save()
        await self.watcher.start()
        self.base_url = f"http://127.0.0.1:{self.server.bound_port}"

    async def asyncTearDown(self) -> None:
        await self.watcher.stop()
        await self.server.stop()
        self._tmp.cleanup()

    async def _http(
        self,
        method: str,
        path: str,
        *,
        body: dict[str, Any] | None = None,
        token: str | None = None,
        send_auth: bool = True,
    ) -> tuple[int, dict[str, str], bytes]:
        def _sync() -> tuple[int, dict[str, str], bytes]:
            headers: dict[str, str] = {}
            if send_auth:
                headers["Authorization"] = f"Bearer {self.token if token is None else token}"
            data: bytes | None = None
            if body is not None:
                data = json.dumps(body).encode("utf-8")
                headers["Content-Type"] = "application/json"
            req = Request(f"{self.base_url}{path}", data=data, headers=headers, method=method)
            try:
                with urlopen(req, timeout=10.0) as resp:
                    return resp.status, {k.lower(): v for k, v in resp.headers.items()}, resp.read()
            except HTTPError as err:
                try:
                    return err.code, {k.lower(): v for k, v in err.headers.items()}, err.read()
                finally:
                    err.close()

        return await asyncio.to_thread(_sync)

    async def _raw_http_status(self, raw_path: str) -> int:
        """Send an un-normalized raw HTTP GET line to test literal `..` traversal handling."""
        reader, writer = await asyncio.open_connection("127.0.0.1", self.server.bound_port)
        try:
            req = (
                f"GET {raw_path} HTTP/1.1\r\n"
                f"Host: 127.0.0.1:{self.server.bound_port}\r\n"
                f"Authorization: Bearer {self.token}\r\n"
                "Connection: close\r\n\r\n"
            ).encode("iso-8859-1")
            writer.write(req)
            await writer.drain()
            first_line = await reader.readline()
            return int(first_line.decode("iso-8859-1").split(" ")[1])
        finally:
            writer.close()
            await writer.wait_closed()

    async def test_ping_and_auth_enforcement(self) -> None:
        # Ping succeeds unauthenticated
        code, _, raw = await self._http("GET", "/api/v1/ping", send_auth=False)
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(raw), {"ok": True, "api_version": "1.0"})

        # Protected endpoints reject missing & wrong tokens
        for path in ("/api/v1/health", "/api/v1/sessions", "/api/v1/approvals"):
            code_no_auth, _, _ = await self._http("GET", path, send_auth=False)
            self.assertEqual(code_no_auth, 401)
            code_bad_auth, _, _ = await self._http("GET", path, token="wrong-token")
            self.assertEqual(code_bad_auth, 401)

        # WebSocket rejects unauthorized handshake
        ws_status, _, ws = await _TestWSClient.connect("127.0.0.1", self.server.bound_port, "/api/v1/ws")
        self.assertEqual(ws_status, 401)
        self.assertIsNone(ws)

        ws_status2, _, ws2 = await _TestWSClient.connect(
            "127.0.0.1",
            self.server.bound_port,
            "/api/v1/ws?token=wrong",
        )
        self.assertEqual(ws_status2, 401)
        self.assertIsNone(ws2)

    async def test_rest_contract_health_sessions_transcript_artifacts_tasks_media(self) -> None:
        # Health
        code, _, raw = await self._http("GET", "/api/v1/health")
        self.assertEqual(code, 200)
        health = json.loads(raw)
        self.assertEqual(health["status"], "ok")
        self.assertEqual(health["api_version"], "1.0")
        self.assertEqual(health["hostname"], "TestWorkstation")
        self.assertTrue(health["brain_dir_exists"])
        self.assertEqual(health["session_count"], 1)
        self.assertEqual(health["total_input_tokens"], 500)
        self.assertEqual(health["total_cache_read_tokens"], 200)
        self.assertEqual(health["total_output_tokens"], 100)
        self.assertTrue(health["server_time"].endswith("Z"))

        # Sessions
        code, _, raw = await self._http("GET", "/api/v1/sessions?limit=50")
        self.assertEqual(code, 200)
        sessions = json.loads(raw)["sessions"]
        self.assertEqual(len(sessions), 1)
        self.assertEqual(sessions[0]["id"], self.session_id)
        self.assertTrue(sessions[0]["has_swarm"])
        self.assertEqual(sessions[0]["artifact_count"], 1)
        self.assertEqual(sessions[0]["task_count"], 1)

        # Transcript compact vs full
        code, _, raw = await self._http("GET", f"/api/v1/sessions/{self.session_id}/transcript?since_step=0&limit=200&full=false")
        self.assertEqual(code, 200)
        tr = json.loads(raw)
        self.assertEqual(tr["session_id"], self.session_id)
        self.assertEqual(tr["total_steps"], 2)
        self.assertEqual(tr["steps"][1]["content"], "Short summary")

        code, _, raw = await self._http("GET", f"/api/v1/sessions/{self.session_id}/transcript?since_step=1&full=true")
        self.assertEqual(code, 200)
        tr_full = json.loads(raw)
        self.assertEqual(len(tr_full["steps"]), 1)
        self.assertEqual(tr_full["steps"][0]["content"], "Full detailed summary")

        # Artifacts list + raw + ?format=json
        code, _, raw = await self._http("GET", f"/api/v1/sessions/{self.session_id}/artifacts")
        self.assertEqual(code, 200)
        arts = json.loads(raw)["artifacts"]
        self.assertEqual(len(arts), 1)
        self.assertEqual(arts[0]["relative_path"], "report.md")

        code, headers, raw = await self._http("GET", f"/api/v1/sessions/{self.session_id}/artifacts/report.md")
        self.assertEqual(code, 200)
        self.assertIn("text/markdown", headers["content-type"])
        self.assertIn(b"Everything green.", raw)

        code, _, raw = await self._http("GET", f"/api/v1/sessions/{self.session_id}/artifacts/report.md?format=json")
        self.assertEqual(code, 200)
        art_json = json.loads(raw)
        self.assertEqual(art_json["name"], "report.md")
        self.assertEqual(art_json["relative_path"], "report.md")
        self.assertEqual(art_json["mime_type"], "text/markdown")
        self.assertIn("Everything green.", art_json["content"])

        # Tasks & Swarms
        code, _, raw = await self._http("GET", f"/api/v1/sessions/{self.session_id}/tasks")
        self.assertEqual(code, 200)
        tasks_resp = json.loads(raw)
        self.assertEqual(len(tasks_resp["tasks"]), 1)
        self.assertIn("build succeeded", tasks_resp["tasks"][0]["tail"])
        self.assertEqual(len(tasks_resp["swarm_events"]), 1)
        self.assertEqual(tasks_resp["swarm_events"][0]["action"], "title")

        # Media
        code, headers, raw = await self._http("GET", f"/api/v1/sessions/{self.session_id}/media/preview.png")
        self.assertEqual(code, 200)
        self.assertEqual(headers["content-type"], "image/png")
        self.assertTrue(raw.startswith(b"\x89PNG"))

        # Path traversal rejections over HTTP
        self.assertEqual(await self._raw_http_status(f"/api/v1/sessions/{self.session_id}/artifacts/../../outside.txt"), 403)
        self.assertEqual(
            await self._raw_http_status(f"/api/v1/sessions/{self.session_id}/artifacts/%2e%2e%2f%2e%2e%2foutside.txt"),
            403,
        )
        self.assertEqual(
            await self._raw_http_status(f"/api/v1/sessions/{self.session_id}/artifacts/.system_generated/logs/transcript.jsonl"),
            403,
        )
        self.assertEqual(await self._raw_http_status(f"/api/v1/sessions/{self.session_id}/media/%2e%2e%2foutside.txt"), 403)

    async def test_websocket_streaming_ping_pong_large_frames_and_live_updates(self) -> None:
        # Connect with ?token= query param
        status, _, ws = await _TestWSClient.connect(
            "127.0.0.1",
            self.server.bound_port,
            f"/api/v1/ws?token={self.token}",
        )
        self.assertEqual(status, 101)
        assert ws is not None
        try:
            hello = await ws.recv_json()
            self.assertEqual(hello["type"], "hello")
            self.assertEqual(hello["health"]["hostname"], "TestWorkstation")

            # Application-level ping -> pong
            await ws.send_json({"type": "ping"})
            pong = await ws.recv_json()
            self.assertEqual(pong["type"], "pong")
            self.assertTrue(pong["timestamp"].endswith("Z"))

            # RFC 6455 control Ping (0x09) -> Pong (0x0A)
            await ws.send_frame(0x09, b"hb-42")
            op, payload = await ws.recv_frame()
            self.assertEqual(op, 0x0A)
            self.assertEqual(payload, b"hb-42")

            # Client->Server > 126 byte masked frame (extended 16-bit length)
            await ws.send_json({"type": "ping", "pad": "x" * 512})
            pong2 = await ws.recv_json()
            self.assertEqual(pong2["type"], "pong")

            # Append a LARGE step (> 70 KiB to exercise 64-bit extended server->client WS framing!)
            big_content = "Z" * 70_000
            new_step = {
                "step_index": 2,
                "source": "MODEL",
                "type": "PLANNER_RESPONSE",
                "status": "DONE",
                "created_at": "2026-11-20T20:31:00Z",
                "model": "gemini-3-pro",
                "content": big_content,
            }
            with self.transcript_path.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(new_step) + "\n")

            seen_types: dict[str, dict[str, Any]] = {}
            for _ in range(4):
                ev = await ws.recv_json(timeout=5.0)
                seen_types[ev["type"]] = ev
                if "step_added" in seen_types and "session_updated" in seen_types:
                    break

            self.assertIn("step_added", seen_types)
            self.assertEqual(seen_types["step_added"]["session_id"], self.session_id)
            self.assertEqual(len(seen_types["step_added"]["step"]["content"]), 70_000)
            self.assertIn("session_updated", seen_types)
            self.assertEqual(seen_types["session_updated"]["session"]["step_count"], 3)
        finally:
            await ws.close()

    async def test_approvals_end_to_end_with_ws_and_conflict_codes(self) -> None:
        # Connect WS using Authorization: Bearer header
        status, _, ws = await _TestWSClient.connect(
            "127.0.0.1",
            self.server.bound_port,
            "/api/v1/ws",
            headers={"Authorization": f"Bearer {self.token}"},
        )
        self.assertEqual(status, 101)
        assert ws is not None
        try:
            _ = await ws.recv_json()  # hello

            # Launch blocking approval request concurrently
            req_task = asyncio.create_task(
                self._http(
                    "POST",
                    "/api/v1/approvals/request",
                    body={
                        "session_id": self.session_id,
                        "hook_event": "PreToolUse",
                        "tool_name": "run_command",
                        "args": {"CommandLine": "git status"},
                        "timeout_seconds": 10,
                        "default_decision": "deny",
                    },
                )
            )

            ev_req = await ws.recv_until_type("approval_requested", timeout=5.0)
            approval_id = ev_req["approval"]["id"]
            self.assertEqual(ev_req["approval"]["status"], "pending")

            # GET /api/v1/approvals shows pending item
            code, _, raw = await self._http("GET", "/api/v1/approvals")
            self.assertEqual(code, 200)
            approvals = json.loads(raw)["approvals"]
            self.assertEqual(approvals[0]["id"], approval_id)

            # Decide allow
            code, _, raw = await self._http(
                "POST",
                f"/api/v1/approvals/{approval_id}/decide",
                body={"decision": "allow", "reason": "Approved from iPhone"},
            )
            self.assertEqual(code, 200)
            decided = json.loads(raw)
            self.assertEqual(decided["status"], "approved")
            self.assertEqual(decided["decision"], "allow")

            # Blocking request resolves with allow
            req_code, _, req_raw = await req_task
            self.assertEqual(req_code, 200)
            req_body = json.loads(req_raw)
            self.assertEqual(req_body["id"], approval_id)
            self.assertEqual(req_body["decision"], "allow")
            self.assertEqual(req_body["status"], "approved")

            # WS receives approval_resolved (may also observe session_updated transition from waiting)
            ev_res = await ws.recv_until_type("approval_resolved", timeout=5.0)
            self.assertEqual(ev_res["approval"]["id"], approval_id)

            # Second decide returns 409 Conflict; unknown ID returns 404
            conflict_code, _, _ = await self._http(
                "POST",
                f"/api/v1/approvals/{approval_id}/decide",
                body={"decision": "deny"},
            )
            self.assertEqual(conflict_code, 409)

            not_found_code, _, _ = await self._http(
                "POST",
                "/api/v1/approvals/apr_missing/decide",
                body={"decision": "allow"},
            )
            self.assertEqual(not_found_code, 404)
        finally:
            await ws.close()

    async def test_hook_script_subprocess_online_and_offline(self) -> None:
        status, _, ws = await _TestWSClient.connect(
            "127.0.0.1",
            self.server.bound_port,
            f"/api/v1/ws?token={self.token}",
        )
        self.assertEqual(status, 101)
        assert ws is not None
        try:
            _ = await ws.recv_json()  # hello

            # 1. PreToolUse hook subprocess approved remotely
            stdin_payload = json.dumps(
                {
                    "conversationId": self.session_id,
                    "hookEventName": "PreToolUse",
                    "toolCall": {
                        "id": "tc_1",
                        "name": "run_command",
                        "args": {"CommandLine": "pytest"},
                    },
                }
            )

            proc = await asyncio.create_subprocess_exec(
                sys.executable,
                str(_HOOK_SCRIPT),
                "--event",
                "PreToolUse",
                "--config-dir",
                str(self.config_dir),
                "--timeout",
                "10",
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            comm_task = asyncio.create_task(proc.communicate(stdin_payload.encode("utf-8")))

            ev_req = await ws.recv_until_type("approval_requested", timeout=5.0)
            approval_id = ev_req["approval"]["id"]
            self.assertEqual(ev_req["approval"]["tool_name"], "run_command")

            await self._http(
                "POST",
                f"/api/v1/approvals/{approval_id}/decide",
                body={"decision": "deny", "reason": "Not on prod"},
            )
            ev_res = await ws.recv_until_type("approval_resolved", timeout=5.0)
            self.assertEqual(ev_res["approval"]["id"], approval_id)

            stdout_bytes, _ = await asyncio.wait_for(comm_task, timeout=10.0)
            self.assertEqual(proc.returncode, 0)
            hook_out = json.loads(stdout_bytes.decode("utf-8"))
            self.assertEqual(hook_out["decision"], "deny")
            self.assertEqual(hook_out["reason"], "Not on prod")

            # 2. Stop hook broadcasts hook_event over WebSocket
            stop_payload = json.dumps(
                {
                    "conversationId": self.session_id,
                    "hookEventName": "Stop",
                    "terminationReason": "NO_TOOL_CALL",
                }
            )
            stop_proc = await asyncio.to_thread(
                subprocess.run,
                [
                    sys.executable,
                    str(_HOOK_SCRIPT),
                    "--event",
                    "Stop",
                    "--config-dir",
                    str(self.config_dir),
                ],
                input=stop_payload,
                text=True,
                capture_output=True,
                timeout=10,
            )
            self.assertEqual(stop_proc.returncode, 0)
            stop_out = json.loads(stop_proc.stdout)
            self.assertNotEqual(stop_out.get("decision"), "continue")

            hook_ev = await ws.recv_until_type("hook_event", timeout=5.0)
            self.assertEqual(hook_ev["hook_event_name"], "Stop")
            self.assertEqual(hook_ev["session_id"], self.session_id)
        finally:
            await ws.close()

        # 3. Offline bridge graceful fallback (unreachable port)
        offline_proc = await asyncio.to_thread(
            subprocess.run,
            [
                sys.executable,
                str(_HOOK_SCRIPT),
                "--event",
                "PreToolUse",
                "--bridge-url",
                "http://127.0.0.1:1",
                "--token",
                "unused",
                "--timeout",
                "2",
            ],
            input=json.dumps({"toolCall": {"name": "run_command", "args": {"CommandLine": "echo hi"}}}),
            text=True,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(offline_proc.returncode, 0)
        self.assertEqual(json.loads(offline_proc.stdout), {"decision": "allow"})

        # Offline deny policy
        offline_deny = await asyncio.to_thread(
            subprocess.run,
            [
                sys.executable,
                str(_HOOK_SCRIPT),
                "--event",
                "PreToolUse",
                "--bridge-url",
                "http://127.0.0.1:1",
                "--token",
                "unused",
                "--offline-decision",
                "deny",
                "--timeout",
                "2",
            ],
            input=json.dumps({"toolCall": {"name": "run_command", "args": {}}}),
            text=True,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(offline_deny.returncode, 0)
        deny_json = json.loads(offline_deny.stdout)
        self.assertEqual(deny_json["decision"], "deny")
        self.assertIn("unreachable", deny_json["reason"].lower())

    async def test_cli_subcommands_install_hooks_pair_qr_and_status(self) -> None:
        # install-hooks preserves existing hooks and follows official schema
        hooks_file = self.root / "hooks.json"
        hooks_file.write_text(json.dumps({"existing-linter": {"enabled": True, "Stop": []}}), encoding="utf-8")

        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = cli_main(
                [
                    "install-hooks",
                    "--target",
                    str(hooks_file),
                    "--config-dir",
                    str(self.config_dir),
                    "--matcher",
                    "run_command",
                ]
            )
        self.assertEqual(rc, 0)
        merged = json.loads(hooks_file.read_text(encoding="utf-8"))
        self.assertIn("existing-linter", merged)
        self.assertIn("antigravity-monitor", merged)
        mon = merged["antigravity-monitor"]
        self.assertIsInstance(mon["PreInvocation"], list)
        self.assertIsInstance(mon["PostInvocation"], list)
        self.assertIsInstance(mon["Stop"], list)
        self.assertEqual(mon["PreToolUse"][0]["matcher"], "run_command")
        self.assertEqual(mon["PreToolUse"][0]["hooks"][0]["timeout"], 60)
        self.assertEqual(mon["PostToolUse"][0]["matcher"], "*")

        # uninstall cleanly removes only antigravity-monitor
        with contextlib.redirect_stdout(io.StringIO()):
            rc_un = cli_main(["install-hooks", "--target", str(hooks_file), "--uninstall"])
        self.assertEqual(rc_un, 0)
        after_un = json.loads(hooks_file.read_text(encoding="utf-8"))
        self.assertIn("existing-linter", after_un)
        self.assertNotIn("antigravity-monitor", after_un)

        # status subcommand connects cleanly to running server
        status_buf = io.StringIO()

        def _run_status() -> int:
            with contextlib.redirect_stdout(status_buf):
                return cli_main(["status", "--config-dir", str(self.config_dir), "--json"])

        rc_status = await asyncio.to_thread(_run_status)
        self.assertEqual(rc_status, 0)
        status_out = json.loads(status_buf.getvalue())
        self.assertTrue(status_out["reachable"])
        self.assertEqual(status_out["health"]["hostname"], "TestWorkstation")

        # pair-qr succeeds cleanly and prints pairing URI + QR art
        qr_buf = io.StringIO()
        with contextlib.redirect_stdout(qr_buf):
            rc_qr = cli_main(["pair-qr", "--config-dir", str(self.config_dir), "--ascii"])
        self.assertEqual(rc_qr, 0)
        self.assertIn("agymon://pair?", qr_buf.getvalue())
        self.assertIn("##", qr_buf.getvalue())


if __name__ == "__main__":
    unittest.main()
