#!/usr/bin/env python3
"""Zero-dependency Google Antigravity 2.0 lifecycle hook script for Antigravity Bridge.

Supports:
  - PreToolUse    : Requests remote iOS approval via POST /api/v1/approvals/request
                    and outputs {"decision": "allow"} or {"decision": "deny", "reason": "..."}.
  - PostToolUse   : Reports tool completion to POST /api/v1/hooks/event and outputs {}.
  - PreInvocation : Reports turn start to POST /api/v1/hooks/event and outputs {}.
  - PostInvocation: Reports model invocation completion to POST /api/v1/hooks/event and outputs {}.
  - SessionStart  : Reports session start to POST /api/v1/hooks/event and outputs {}.
  - Stop          : Reports turn completion to POST /api/v1/hooks/event and outputs {"decision": "stop"}.

Always prints valid JSON to stdout and exits 0 so offline bridge servers never break Antigravity.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


DEFAULT_BRIDGE_URL = "http://127.0.0.1:8765"


def _load_bridge_config(config_dir: str | None) -> dict[str, Any]:
    base = (
        Path(config_dir).expanduser()
        if config_dir
        else Path(os.environ.get("ANTIGRAVITY_BRIDGE_CONFIG_DIR", "~/.antigravity-bridge")).expanduser()
    )
    cfg_file = base / "config.json"
    if not cfg_file.is_file():
        return {}
    try:
        data = json.loads(cfg_file.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def _read_stdin_json() -> dict[str, Any]:
    if sys.stdin is None or sys.stdin.isatty():
        return {}
    try:
        raw = sys.stdin.read()
    except OSError:
        return {}
    text = raw.strip()
    if not text:
        return {}
    try:
        parsed = json.loads(text)
        return parsed if isinstance(parsed, dict) else {"raw": parsed}
    except json.JSONDecodeError:
        return {"raw": text}


def _extract_session_id(payload: dict[str, Any]) -> str | None:
    for key in ("conversationId", "conversation_id", "sessionId", "session_id"):
        val = payload.get(key)
        if isinstance(val, str) and val.strip():
            return val.strip()
    return None


def _extract_tool_info(payload: dict[str, Any]) -> tuple[str | None, dict[str, Any]]:
    tool_call = payload.get("toolCall")
    if isinstance(tool_call, dict):
        name = tool_call.get("name")
        args = tool_call.get("args")
        return (
            str(name) if name else None,
            args if isinstance(args, dict) else {},
        )

    name = payload.get("tool_name") or payload.get("toolName") or payload.get("tool")
    args = payload.get("args") or payload.get("tool_args") or payload.get("toolArgs") or {}
    return (
        str(name) if name else None,
        args if isinstance(args, dict) else {},
    )


def _summarize_event(event: str, tool_name: str | None, args: dict[str, Any], payload: dict[str, Any]) -> str:
    if tool_name:
        for key in ("CommandLine", "command", "cmd"):
            val = args.get(key)
            if isinstance(val, str) and val.strip():
                snippet = val.strip().replace("\n", " ")[:120]
                return f"{tool_name}: {snippet}"
        for key in ("Path", "path", "TargetFile", "file_path"):
            val = args.get(key)
            if isinstance(val, str) and val.strip():
                return f"{tool_name}: {val.strip()}"
        if payload.get("error"):
            return f"{tool_name} failed: {str(payload['error'])[:120]}"
        return f"{event}: {tool_name}"

    if event == "Stop":
        reason = payload.get("terminationReason") or payload.get("reason")
        err = payload.get("error")
        if err:
            return f"Session stopped with error: {str(err)[:120]}"
        if reason:
            return f"Session stopped ({reason})"
        return "Session turn completed"

    last_input = payload.get("lastUserInput")
    if isinstance(last_input, str) and last_input.strip():
        return f"{event}: {last_input.strip().replace(chr(10), ' ')[:120]}"

    return event


def _post_json(url: str, token: str, body: dict[str, Any], timeout: float) -> dict[str, Any]:
    encoded = json.dumps(body, ensure_ascii=False).encode("utf-8")
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = Request(url, data=encoded, headers=headers, method="POST")
    with urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8", errors="replace")
        return json.loads(raw) if raw.strip() else {}


def _emit_stdout(obj: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Google Antigravity 2.0 hook client for Antigravity Bridge.")
    parser.add_argument(
        "--event",
        default=None,
        help="Hook event name (PreToolUse, PostToolUse, PreInvocation, PostInvocation, SessionStart, Stop).",
    )
    parser.add_argument("--bridge-url", default=None, help="Bridge base URL (default: env/config or http://127.0.0.1:8765).")
    parser.add_argument("--token", default=None, help="Bridge bearer token (default: env/config).")
    parser.add_argument("--config-dir", default=None, help="Bridge config directory containing config.json.")
    parser.add_argument(
        "--timeout",
        type=float,
        default=55.0,
        help="Remote approval wait timeout in seconds for PreToolUse (default: 55).",
    )
    parser.add_argument(
        "--timeout-decision",
        choices=("allow", "deny"),
        default=os.environ.get("ANTIGRAVITY_BRIDGE_TIMEOUT_DECISION", "deny"),
        help="Decision applied if remote approval times out (default: deny).",
    )
    parser.add_argument(
        "--offline-decision",
        choices=("allow", "deny"),
        default=os.environ.get("ANTIGRAVITY_BRIDGE_OFFLINE_DECISION", "allow"),
        help="Fallback decision when the bridge server is offline/unreachable (default: allow).",
    )
    parser.add_argument("--debug", action="store_true", help="Log diagnostic errors to stderr.")
    args = parser.parse_args(argv)

    stdin_payload = _read_stdin_json()
    event = (
        args.event
        or (str(stdin_payload["hookEventName"]) if stdin_payload.get("hookEventName") else None)
        or (str(stdin_payload["event"]) if stdin_payload.get("event") else None)
        or "PreInvocation"
    )

    cfg = _load_bridge_config(args.config_dir)
    bridge_url = (
        args.bridge_url
        or os.environ.get("ANTIGRAVITY_BRIDGE_URL")
        or str(cfg.get("bridge_url") or "")
        or (f"http://127.0.0.1:{cfg['port']}" if cfg.get("port") else DEFAULT_BRIDGE_URL)
    ).rstrip("/")
    token = args.token or os.environ.get("ANTIGRAVITY_BRIDGE_TOKEN") or str(cfg.get("token") or "")

    session_id = _extract_session_id(stdin_payload)
    tool_name, tool_args = _extract_tool_info(stdin_payload)
    summary = _summarize_event(event, tool_name, tool_args, stdin_payload)

    if event == "PreToolUse":
        req_body = {
            "session_id": session_id,
            "hook_event": "PreToolUse",
            "tool_name": tool_name or "unknown_tool",
            "args": tool_args,
            "summary": summary,
            "timeout_seconds": max(1, int(round(args.timeout))),
            "default_decision": args.timeout_decision,
        }
        try:
            resp = _post_json(
                f"{bridge_url}/api/v1/approvals/request",
                token,
                req_body,
                timeout=max(2.0, float(args.timeout) + 5.0),
            )
            decision = resp.get("decision")
            reason = resp.get("reason")
            if decision == "allow":
                _emit_stdout({"decision": "allow"})
                return 0
            if decision == "deny":
                out: dict[str, Any] = {"decision": "deny"}
                if isinstance(reason, str) and reason.strip():
                    out["reason"] = reason.strip()
                else:
                    out["reason"] = "Denied remotely from Antigravity Monitor."
                _emit_stdout(out)
                return 0
        except HTTPError as exc:
            if args.debug:
                print(f"[antigravity_hook] bridge approval HTTP error: {exc}", file=sys.stderr)
            exc.close()
        except (URLError, OSError, TimeoutError, json.JSONDecodeError) as exc:
            if args.debug:
                print(f"[antigravity_hook] bridge approval request failed: {exc}", file=sys.stderr)

        fallback = args.offline_decision
        if fallback == "allow":
            _emit_stdout({"decision": "allow"})
        else:
            _emit_stdout(
                {
                    "decision": "deny",
                    "reason": "Antigravity Bridge is unreachable; offline fallback policy is deny.",
                }
            )
        return 0

    # Non-blocking notification hook events: PreInvocation, PostInvocation, PostToolUse, SessionStart, Stop
    event_body = {
        "event": event,
        "session_id": session_id,
        "tool_name": tool_name,
        "summary": summary,
        "payload": stdin_payload,
    }
    try:
        _post_json(f"{bridge_url}/api/v1/hooks/event", token, event_body, timeout=3.0)
    except HTTPError as exc:
        if args.debug:
            print(f"[antigravity_hook] bridge event HTTP error: {exc}", file=sys.stderr)
        exc.close()
    except (URLError, OSError, TimeoutError, json.JSONDecodeError) as exc:
        if args.debug:
            print(f"[antigravity_hook] bridge event notification failed: {exc}", file=sys.stderr)

    if event == "Stop":
        _emit_stdout({"decision": "stop"})
    else:
        _emit_stdout({})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
