"""Configuration, pairing URI generation, and bearer token helpers."""

from __future__ import annotations

import hmac
import json
import os
import secrets
import socket
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote


DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 8765
DEFAULT_POLL_INTERVAL = 1.0
DEFAULT_HEALTH_TICK_INTERVAL = 15.0
DEFAULT_ACTIVE_THRESHOLD_SECONDS = 120


def default_brain_dir() -> Path:
    """Return the default Antigravity 2.0 brain directory."""
    env_dir = os.environ.get("ANTIGRAVITY_BRAIN_DIR")
    if env_dir:
        return Path(env_dir).expanduser()
    return Path.home() / ".gemini" / "antigravity" / "brain"


def default_config_dir() -> Path:
    """Return the default bridge configuration directory."""
    env_dir = os.environ.get("ANTIGRAVITY_BRIDGE_CONFIG_DIR")
    if env_dir:
        return Path(env_dir).expanduser()
    return Path.home() / ".antigravity-bridge"


def detect_lan_ip() -> str:
    """Best-effort detection of the host's primary LAN IPv4 address without sending traffic."""
    sock: socket.socket | None = None
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(0.2)
        sock.connect(("192.0.2.1", 80))
        ip = sock.getsockname()[0]
        if ip and not ip.startswith("127.") and ip != "0.0.0.0":
            return ip
    except OSError:
        pass
    finally:
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass

    try:
        hostname_ip = socket.gethostbyname(socket.gethostname())
        if hostname_ip and not hostname_ip.startswith("127.") and hostname_ip != "0.0.0.0":
            return hostname_ip
    except OSError:
        pass

    return "127.0.0.1"


def generate_token() -> str:
    """Generate a cryptographically secure URL-safe bearer token."""
    return secrets.token_urlsafe(32)


def verify_token(candidate: str | None, expected: str) -> bool:
    """Constant-time bearer token verification using hmac.compare_digest."""
    if not candidate or not expected:
        return False
    return hmac.compare_digest(candidate.encode("utf-8"), expected.encode("utf-8"))


def build_pairing_uri(base_url: str, token: str, host_name: str) -> str:
    """Build the frozen v1 pairing deep link URI for QR scanning / Universal Links.

    Format:
        agymon://pair?url=<percent-encoded-base-url>&token=<token>&name=<percent-encoded-host-name>
    """
    normalized_url = base_url.rstrip("/")
    encoded_url = quote(normalized_url, safe="")
    encoded_token = quote(token, safe="")
    encoded_name = quote(host_name, safe="")
    return f"agymon://pair?url={encoded_url}&token={encoded_token}&name={encoded_name}"


@dataclass(slots=True)
class BridgeConfig:
    """Runtime configuration for the Antigravity Bridge server."""

    host: str = DEFAULT_HOST
    port: int = DEFAULT_PORT
    token: str = ""
    brain_dir: Path = default_brain_dir()
    config_dir: Path = default_config_dir()
    host_name: str = ""
    advertise_url: str | None = None
    poll_interval: float = DEFAULT_POLL_INTERVAL
    health_tick_interval: float = DEFAULT_HEALTH_TICK_INTERVAL
    active_threshold_seconds: int = DEFAULT_ACTIVE_THRESHOLD_SECONDS
    enable_bonjour: bool = True

    def __post_init__(self) -> None:
        self.brain_dir = Path(self.brain_dir).expanduser()
        self.config_dir = Path(self.config_dir).expanduser()
        if not self.host_name:
            self.host_name = socket.gethostname() or "Antigravity-Host"

    @property
    def config_file(self) -> Path:
        return self.config_dir / "config.json"

    def resolved_advertise_url(self) -> str:
        """Return the base URL advertised to iOS clients (e.g. http://192.168.1.42:8765)."""
        if self.advertise_url:
            return self.advertise_url.rstrip("/")
        if self.host in ("0.0.0.0", "::", ""):
            ip = detect_lan_ip()
        else:
            ip = self.host
        return f"http://{ip}:{self.port}"

    def local_url(self) -> str:
        """Return the loopback URL used by local lifecycle hooks."""
        connect_host = "127.0.0.1" if self.host in ("0.0.0.0", "::", "") else self.host
        return f"http://{connect_host}:{self.port}"

    def pairing_uri(self) -> str:
        """Return the pairing URI for this bridge configuration."""
        return build_pairing_uri(self.resolved_advertise_url(), self.token, self.host_name)

    def save(self) -> None:
        """Persist non-ephemeral bridge configuration to disk."""
        self.config_dir.mkdir(parents=True, exist_ok=True)
        payload = {
            "host": self.host,
            "port": self.port,
            "token": self.token,
            "brain_dir": str(self.brain_dir),
            "host_name": self.host_name,
            "advertise_url": self.advertise_url,
            "bridge_url": self.local_url(),
        }
        tmp_path = self.config_file.with_suffix(".tmp")
        tmp_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        tmp_path.replace(self.config_file)
        if os.name != "nt":
            try:
                os.chmod(self.config_file, 0o600)
            except OSError:
                pass


def load_or_create_config(
    *,
    config_dir: Path | str | None = None,
    brain_dir: Path | str | None = None,
    host: str | None = None,
    port: int | None = None,
    token: str | None = None,
    rotate_token: bool = False,
    host_name: str | None = None,
    advertise_url: str | None = None,
    poll_interval: float | None = None,
    health_tick_interval: float | None = None,
    enable_bonjour: bool = True,
    persist: bool = True,
) -> BridgeConfig:
    """Load saved bridge config, merge env & CLI overrides, and persist generated tokens."""
    resolved_config_dir = Path(config_dir).expanduser() if config_dir else default_config_dir()
    config_file = resolved_config_dir / "config.json"

    saved: dict[str, object] = {}
    if config_file.is_file():
        try:
            loaded = json.loads(config_file.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                saved = loaded
        except (OSError, json.JSONDecodeError):
            saved = {}

    final_host = (
        host
        or os.environ.get("ANTIGRAVITY_BRIDGE_HOST")
        or (str(saved["host"]) if saved.get("host") else DEFAULT_HOST)
    )

    env_port = os.environ.get("ANTIGRAVITY_BRIDGE_PORT")
    if port is not None:
        final_port = int(port)
    elif env_port:
        final_port = int(env_port)
    elif isinstance(saved.get("port"), int):
        final_port = int(saved["port"])
    else:
        final_port = DEFAULT_PORT

    if brain_dir is not None:
        final_brain_dir = Path(brain_dir).expanduser()
    elif os.environ.get("ANTIGRAVITY_BRAIN_DIR"):
        final_brain_dir = Path(os.environ["ANTIGRAVITY_BRAIN_DIR"]).expanduser()
    elif saved.get("brain_dir"):
        final_brain_dir = Path(str(saved["brain_dir"])).expanduser()
    else:
        final_brain_dir = default_brain_dir()

    final_host_name = (
        host_name
        or os.environ.get("ANTIGRAVITY_BRIDGE_NAME")
        or (str(saved["host_name"]) if saved.get("host_name") else socket.gethostname() or "Antigravity-Host")
    )

    final_advertise_url = (
        advertise_url
        or os.environ.get("ANTIGRAVITY_BRIDGE_ADVERTISE_URL")
        or (str(saved["advertise_url"]) if saved.get("advertise_url") else None)
    )

    dirty = False
    if rotate_token:
        final_token = generate_token()
        dirty = True
    elif token:
        final_token = token
    elif os.environ.get("ANTIGRAVITY_BRIDGE_TOKEN"):
        final_token = os.environ["ANTIGRAVITY_BRIDGE_TOKEN"]
    elif saved.get("token"):
        final_token = str(saved["token"])
    else:
        final_token = generate_token()
        dirty = True

    cfg = BridgeConfig(
        host=final_host,
        port=final_port,
        token=final_token,
        brain_dir=final_brain_dir,
        config_dir=resolved_config_dir,
        host_name=final_host_name,
        advertise_url=final_advertise_url,
        poll_interval=poll_interval if poll_interval is not None else DEFAULT_POLL_INTERVAL,
        health_tick_interval=(
            health_tick_interval if health_tick_interval is not None else DEFAULT_HEALTH_TICK_INTERVAL
        ),
        enable_bonjour=enable_bonjour,
    )

    if persist and (dirty or not config_file.is_file()):
        cfg.save()

    return cfg
