"""Optional Bonjour/mDNS advertisement for LAN discovery (_antigravity-mon._tcp)."""

from __future__ import annotations

import logging
import socket

from . import API_VERSION

try:
    from zeroconf import ServiceInfo, Zeroconf  # type: ignore[import-not-found]

    ZEROCONF_AVAILABLE = True
except ImportError:
    ServiceInfo = None  # type: ignore[assignment]
    Zeroconf = None  # type: ignore[assignment]
    ZEROCONF_AVAILABLE = False


LOGGER = logging.getLogger("antigravity_bridge.bonjour")
SERVICE_TYPE = "_antigravity-mon._tcp.local."


class BonjourAdvertiser:
    """Advertises the Antigravity Bridge over LAN Bonjour when optional zeroconf is installed."""

    def __init__(self) -> None:
        self._zeroconf: object | None = None
        self._info: object | None = None

    @staticmethod
    def is_available() -> bool:
        return ZEROCONF_AVAILABLE

    def start(
        self,
        *,
        name: str,
        host_ip: str,
        port: int,
        api_version: str = API_VERSION,
        hostname: str | None = None,
    ) -> bool:
        """Start advertising `_antigravity-mon._tcp.local.`. Returns True if active."""
        if not ZEROCONF_AVAILABLE or Zeroconf is None or ServiceInfo is None:
            LOGGER.info(
                "Optional 'zeroconf' package not installed; skipping Bonjour advertisement "
                "(install with `pip install '.[bonjour]'` to enable LAN auto-discovery)."
            )
            return False

        try:
            ip_bytes = socket.inet_aton(host_ip)
        except OSError:
            try:
                ip_bytes = socket.inet_aton(socket.gethostbyname(host_ip))
            except OSError:
                ip_bytes = socket.inet_aton("127.0.0.1")

        safe_name = name.replace(".", "-").strip() or "Antigravity-Bridge"
        full_service_name = f"{safe_name}.{SERVICE_TYPE}"
        server_host = f"{(hostname or safe_name).split('.')[0]}.local."
        properties = {
            "api_version": api_version,
            "hostname": hostname or safe_name,
            "path": "/api/v1",
        }

        try:
            info = ServiceInfo(
                SERVICE_TYPE,
                full_service_name,
                addresses=[ip_bytes],
                port=port,
                properties=properties,
                server=server_host,
            )
            zc = Zeroconf()
            zc.register_service(info)
            self._zeroconf = zc
            self._info = info
            LOGGER.info("Advertising Bonjour service %s on %s:%d", full_service_name, host_ip, port)
            return True
        except Exception as exc:
            LOGGER.warning("Failed to advertise Bonjour service: %s", exc)
            self.stop()
            return False

    def stop(self) -> None:
        """Unregister and close the Bonjour advertiser cleanly."""
        zc = self._zeroconf
        info = self._info
        self._zeroconf = None
        self._info = None
        if zc is not None:
            try:
                if info is not None:
                    zc.unregister_service(info)  # type: ignore[attr-defined]
            except Exception:
                pass
            try:
                zc.close()  # type: ignore[attr-defined]
            except Exception:
                pass
