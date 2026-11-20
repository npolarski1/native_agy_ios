"""CLI entry point for Antigravity Bridge (`serve`, `pair-qr`, `install-hooks`, `status`)."""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import signal
import sys
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from . import API_VERSION, __version__
from .bonjour import BonjourAdvertiser
from .config import BridgeConfig, detect_lan_ip, load_or_create_config
from .qr import encode_qr
from .server import BridgeServer
from .watcher import BrainWatcher


def _resolve_hook_script_path() -> Path:
    """Locate bridge/hooks/antigravity_hook.py relative to this package."""
    pkg_dir = Path(__file__).resolve().parent
    candidates = [
        pkg_dir.parent / "hooks" / "antigravity_hook.py",
        Path.cwd() / "bridge" / "hooks" / "antigravity_hook.py",
        Path.cwd() / "hooks" / "antigravity_hook.py",
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return candidates[0]


def _quote_cmd_arg(value: str) -> str:
    if any(ch in value for ch in (' ', '\t', '"', "'")):
        escaped = value.replace('"', '\\"')
        return f'"{escaped}"'
    return value


def build_hooks_entry(
    *,
    python_executable: str,
    hook_script: Path,
    matcher: str = "run_command|write_file|edit_file",
    pre_tool_timeout: int = 60,
    event_timeout: int = 30,
    bridge_url: str | None = None,
    config_dir: Path | None = None,
) -> dict[str, Any]:
    """Build an official Antigravity 2.0 `hooks.json` named hook specification."""
    base_parts = [_quote_cmd_arg(python_executable), _quote_cmd_arg(str(hook_script))]
    if bridge_url:
        base_parts.extend(["--bridge-url", _quote_cmd_arg(bridge_url)])
    if config_dir:
        base_parts.extend(["--config-dir", _quote_cmd_arg(str(config_dir))])
    base_cmd = " ".join(base_parts)

    approval_wait = max(5, pre_tool_timeout - 5)

    return {
        "enabled": True,
        "PreInvocation": [
            {
                "type": "command",
                "command": f"{base_cmd} --event PreInvocation",
                "timeout": event_timeout,
            }
        ],
        "PostInvocation": [
            {
                "type": "command",
                "command": f"{base_cmd} --event PostInvocation",
                "timeout": event_timeout,
            }
        ],
        "PreToolUse": [
            {
                "matcher": matcher,
                "hooks": [
                    {
                        "type": "command",
                        "command": f"{base_cmd} --event PreToolUse --timeout {approval_wait}",
                        "timeout": pre_tool_timeout,
                    }
                ],
            }
        ],
        "PostToolUse": [
            {
                "matcher": "*",
                "hooks": [
                    {
                        "type": "command",
                        "command": f"{base_cmd} --event PostToolUse",
                        "timeout": event_timeout,
                    }
                ],
            }
        ],
        "Stop": [
            {
                "type": "command",
                "command": f"{base_cmd} --event Stop",
                "timeout": event_timeout,
            }
        ],
    }


def _print_pairing_banner(cfg: BridgeConfig, *, show_qr: bool = True, ascii_only: bool = False, invert: bool = True) -> None:
    uri = cfg.pairing_uri()
    print(f"Antigravity Bridge v{__version__} (API {API_VERSION})")
    print(f"  Host Name     : {cfg.host_name}")
    print(f"  Local URL     : {cfg.local_url()}")
    print(f"  Advertise URL : {cfg.resolved_advertise_url()}")
    print(f"  Brain Dir     : {cfg.brain_dir} ({'found' if cfg.brain_dir.is_dir() else 'not found yet'})")
    print(f"  Config File   : {cfg.config_file}")
    print(f"  Pairing URI   : {uri}")
    if show_qr:
        qr = encode_qr(uri, ec_level="L")
        print("\nScan this QR code in Antigravity Monitor for iOS:\n")
        if ascii_only:
            print(qr.render_ascii(border=2))
        else:
            try:
                print(qr.render_terminal(border=2, invert=invert))
            except UnicodeEncodeError:
                print(qr.render_ascii(border=2))
        print()


async def _run_serve(cfg: BridgeConfig, *, show_qr: bool, ascii_qr: bool, invert_qr: bool) -> int:
    server = BridgeServer(cfg)
    watcher = BrainWatcher(
        server.store,
        server.broadcast_event,
        server.get_health,
        pending_session_ids_provider=server.approvals.pending_session_ids,
        hook_hints_provider=server.hook_status_hints,
        poll_interval=cfg.poll_interval,
        health_tick_interval=cfg.health_tick_interval,
    )
    bonjour = BonjourAdvertiser()

    await server.start()
    if cfg.port == 0:
        cfg.port = server.bound_port

    if cfg.enable_bonjour:
        lan_ip = detect_lan_ip() if cfg.host in ("0.0.0.0", "::", "") else cfg.host
        bonjour.start(
            name=cfg.host_name,
            host_ip=lan_ip,
            port=server.bound_port,
            api_version=API_VERSION,
            hostname=cfg.host_name,
        )

    await watcher.start()
    _print_pairing_banner(cfg, show_qr=show_qr, ascii_only=ascii_qr, invert=invert_qr)

    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()

    def _request_stop() -> None:
        stop_event.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, _request_stop)
        except (NotImplementedError, RuntimeError):
            # Windows ProactorEventLoop does not support add_signal_handler; KeyboardInterrupt handles Ctrl+C.
            pass

    try:
        await stop_event.wait()
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass
    finally:
        await watcher.stop()
        bonjour.stop()
        await server.stop()

    return 0


def _cmd_serve(args: argparse.Namespace) -> int:
    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )
    cfg = load_or_create_config(
        config_dir=args.config_dir,
        brain_dir=args.brain_dir,
        host=args.host,
        port=args.port,
        token=args.token,
        rotate_token=args.rotate_token,
        host_name=args.name,
        advertise_url=args.advertise_url,
        poll_interval=args.poll_interval,
        enable_bonjour=not args.no_bonjour,
        persist=True,
    )
    try:
        return asyncio.run(
            _run_serve(
                cfg,
                show_qr=not args.no_qr,
                ascii_qr=args.ascii_qr,
                invert_qr=not args.light_terminal,
            )
        )
    except KeyboardInterrupt:
        return 0


def _cmd_pair_qr(args: argparse.Namespace) -> int:
    cfg = load_or_create_config(
        config_dir=args.config_dir,
        brain_dir=args.brain_dir,
        host=args.host,
        port=args.port,
        token=args.token,
        rotate_token=args.rotate_token,
        host_name=args.name,
        advertise_url=args.advertise_url,
        persist=True,
    )
    _print_pairing_banner(
        cfg,
        show_qr=True,
        ascii_only=args.ascii,
        invert=not args.light_terminal,
    )
    return 0


def _cmd_install_hooks(args: argparse.Namespace) -> int:
    if args.target:
        hooks_path = Path(args.target).expanduser()
    elif args.scope == "workspace":
        hooks_path = Path.cwd() / ".agents" / "hooks.json"
    else:
        hooks_path = Path.home() / ".gemini" / "config" / "hooks.json"

    existing: dict[str, Any] = {}
    if hooks_path.is_file():
        try:
            loaded = json.loads(hooks_path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                existing = loaded
            else:
                print(f"Error: {hooks_path} does not contain a top-level JSON object.", file=sys.stderr)
                return 1
        except (OSError, json.JSONDecodeError) as exc:
            print(f"Error reading {hooks_path}: {exc}", file=sys.stderr)
            return 1

    hook_key = args.hook_name
    if args.uninstall:
        removed = existing.pop(hook_key, None)
        if removed is None:
            print(f"Hook '{hook_key}' was not installed in {hooks_path}.")
            return 0
    else:
        hook_script = Path(args.hook_script).expanduser().resolve() if args.hook_script else _resolve_hook_script_path()
        config_dir = Path(args.config_dir).expanduser() if args.config_dir else None
        existing[hook_key] = build_hooks_entry(
            python_executable=args.python or sys.executable,
            hook_script=hook_script,
            matcher=args.matcher,
            pre_tool_timeout=args.timeout,
            bridge_url=args.bridge_url,
            config_dir=config_dir,
        )

    rendered = json.dumps(existing, indent=2) + "\n"
    if args.dry_run:
        print(rendered)
        return 0

    hooks_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = hooks_path.with_suffix(".tmp")
    tmp_path.write_text(rendered, encoding="utf-8")
    tmp_path.replace(hooks_path)
    action = "Removed" if args.uninstall else "Installed"
    print(f"{action} '{hook_key}' hooks in {hooks_path}")
    return 0


def _cmd_status(args: argparse.Namespace) -> int:
    cfg = load_or_create_config(
        config_dir=args.config_dir,
        host=args.host,
        port=args.port,
        token=args.token,
        persist=False,
    )
    base_url = (args.url or cfg.local_url()).rstrip("/")
    timeout = max(0.5, float(args.timeout))

    try:
        ping_req = Request(f"{base_url}/api/v1/ping", method="GET")
        with urlopen(ping_req, timeout=timeout) as resp:
            ping_data = json.loads(resp.read().decode("utf-8"))
    except (URLError, HTTPError, OSError, json.JSONDecodeError) as exc:
        if args.json:
            print(json.dumps({"reachable": False, "url": base_url, "error": str(exc)}))
        else:
            print(f"Antigravity Bridge at {base_url} is UNREACHABLE: {exc}")
        return 1

    health_data: dict[str, Any] | None = None
    health_error: str | None = None
    try:
        health_req = Request(
            f"{base_url}/api/v1/health",
            headers={"Authorization": f"Bearer {cfg.token}"},
            method="GET",
        )
        with urlopen(health_req, timeout=timeout) as resp:
            health_data = json.loads(resp.read().decode("utf-8"))
    except HTTPError as exc:
        health_error = f"HTTP {exc.code}: {exc.reason}"
        exc.close()
    except (URLError, OSError, json.JSONDecodeError) as exc:
        health_error = str(exc)

    if args.json:
        print(
            json.dumps(
                {
                    "reachable": True,
                    "url": base_url,
                    "ping": ping_data,
                    "health": health_data,
                    "health_error": health_error,
                },
                indent=2,
            )
        )
        return 0 if health_data is not None else 1

    print(f"Antigravity Bridge at {base_url}: ONLINE (api_version={ping_data.get('api_version')})")
    if health_data is not None:
        print(f"  Hostname          : {health_data.get('hostname')}")
        print(f"  Platform          : {health_data.get('platform')}")
        print(f"  Uptime            : {health_data.get('uptime_seconds')}s")
        print(f"  Brain Dir         : {health_data.get('brain_dir')} (exists={health_data.get('brain_dir_exists')})")
        print(
            f"  Sessions          : {health_data.get('session_count')} total, "
            f"{health_data.get('active_session_count')} active"
        )
        print(f"  Pending Approvals : {health_data.get('pending_approval_count')}")
        print(
            f"  Tokens            : in={health_data.get('total_input_tokens')} "
            f"cache={health_data.get('total_cache_read_tokens')} "
            f"out={health_data.get('total_output_tokens')}"
        )
        return 0

    print(f"  Health Check Failed: {health_error}")
    return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="antigravity-bridge",
        description="Companion bridge server and lifecycle hook manager for Google Antigravity 2.0.",
    )
    parser.add_argument("--version", action="version", version=f"antigravity-bridge {__version__}")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # serve
    serve_p = subparsers.add_parser("serve", help="Run the Antigravity Bridge HTTP/WebSocket server.")
    serve_p.add_argument("--host", default=None, help="Bind host (default: 0.0.0.0).")
    serve_p.add_argument("--port", type=int, default=None, help="Bind port (default: 8765).")
    serve_p.add_argument("--brain-dir", default=None, help="Path to ~/.gemini/antigravity/brain.")
    serve_p.add_argument("--config-dir", default=None, help="Path to bridge config directory.")
    serve_p.add_argument("--token", default=None, help="Override bearer token.")
    serve_p.add_argument("--rotate-token", action="store_true", help="Generate and persist a new bearer token.")
    serve_p.add_argument("--name", default=None, help="Display name advertised to iOS devices.")
    serve_p.add_argument("--advertise-url", default=None, help="External URL for QR pairing (e.g. Tailscale URL).")
    serve_p.add_argument("--poll-interval", type=float, default=None, help="Brain directory poll interval in seconds.")
    serve_p.add_argument("--no-bonjour", action="store_true", help="Disable optional Bonjour LAN advertising.")
    serve_p.add_argument("--no-qr", action="store_true", help="Do not print the pairing QR code on startup.")
    serve_p.add_argument("--ascii-qr", action="store_true", help="Render QR code using pure ASCII characters.")
    serve_p.add_argument("--light-terminal", action="store_true", help="Render QR code for light terminal backgrounds.")
    serve_p.add_argument("--log-level", default="INFO", help="Logging level (DEBUG, INFO, WARNING, ERROR).")
    serve_p.set_defaults(func=_cmd_serve)

    # pair-qr
    qr_p = subparsers.add_parser("pair-qr", help="Print the agymon:// pairing URI and terminal QR code.")
    qr_p.add_argument("--host", default=None, help="Configured bind host.")
    qr_p.add_argument("--port", type=int, default=None, help="Configured port.")
    qr_p.add_argument("--brain-dir", default=None, help="Configured brain directory.")
    qr_p.add_argument("--config-dir", default=None, help="Path to bridge config directory.")
    qr_p.add_argument("--token", default=None, help="Override bearer token.")
    qr_p.add_argument("--rotate-token", action="store_true", help="Generate and persist a new bearer token.")
    qr_p.add_argument("--name", default=None, help="Display host name.")
    qr_p.add_argument("--advertise-url", default=None, help="Explicit base URL to encode in the pairing URI.")
    qr_p.add_argument("--ascii", action="store_true", help="Render QR code using pure ASCII characters.")
    qr_p.add_argument("--light-terminal", action="store_true", help="Render QR code for light terminal backgrounds.")
    qr_p.set_defaults(func=_cmd_pair_qr)

    # install-hooks
    hooks_p = subparsers.add_parser("install-hooks", help="Install or remove Antigravity 2.0 hooks.json entries.")
    hooks_p.add_argument(
        "--scope",
        choices=("global", "workspace"),
        default="global",
        help="Install into ~/.gemini/config/hooks.json (global) or ./.agents/hooks.json (workspace).",
    )
    hooks_p.add_argument("--target", default=None, help="Explicit hooks.json file path (overrides --scope).")
    hooks_p.add_argument("--hook-name", default="antigravity-monitor", help="Top-level key in hooks.json.")
    hooks_p.add_argument(
        "--matcher",
        default="run_command|write_file|edit_file",
        help="Tool matcher regex for PreToolUse remote approval gating.",
    )
    hooks_p.add_argument("--timeout", type=int, default=60, help="PreToolUse hook timeout in seconds (default: 60).")
    hooks_p.add_argument("--bridge-url", default=None, help="Explicit bridge URL passed to hook script.")
    hooks_p.add_argument("--config-dir", default=None, help="Bridge config directory passed to hook script.")
    hooks_p.add_argument("--hook-script", default=None, help="Explicit path to antigravity_hook.py.")
    hooks_p.add_argument("--python", default=None, help="Python executable path to invoke in hooks.json.")
    hooks_p.add_argument("--dry-run", action="store_true", help="Print resulting hooks.json without modifying disk.")
    hooks_p.add_argument("--uninstall", action="store_true", help="Remove the hook entry from hooks.json.")
    hooks_p.set_defaults(func=_cmd_install_hooks)

    # status
    status_p = subparsers.add_parser("status", help="Check bridge connectivity and host telemetry.")
    status_p.add_argument("--url", default=None, help="Bridge base URL (default: from config).")
    status_p.add_argument("--host", default=None, help="Bridge host override.")
    status_p.add_argument("--port", type=int, default=None, help="Bridge port override.")
    status_p.add_argument("--token", default=None, help="Bearer token override.")
    status_p.add_argument("--config-dir", default=None, help="Path to bridge config directory.")
    status_p.add_argument("--timeout", type=float, default=5.0, help="HTTP timeout in seconds.")
    status_p.add_argument("--json", action="store_true", help="Output raw JSON status.")
    status_p.set_defaults(func=_cmd_status)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
