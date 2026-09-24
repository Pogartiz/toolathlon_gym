"""Force IPv4 for outbound sockets inside Toolathlon-GYM containers.

Docker Desktop bridge networks often advertise AAAA records for public API
hosts while IPv6 routing is unreachable. CAMEL/httpx then stalls in async
``getaddrinfo`` / Happy Eyeballs until the agent step timeout fires.
"""

from __future__ import annotations

import socket
from typing import Any

_PATCHED = False
_ORIG_GETADDRINFO = socket.getaddrinfo


def install_ipv4_only_getaddrinfo() -> None:
    """Prefer AF_INET results; fall back to the original resolver if empty."""
    global _PATCHED
    if _PATCHED:
        return

    def _getaddrinfo(host: Any, port: Any, family: int = 0, type: int = 0, proto: int = 0, flags: int = 0):
        if family in (0, socket.AF_UNSPEC):
            try:
                return _ORIG_GETADDRINFO(host, port, socket.AF_INET, type, proto, flags)
            except OSError:
                return _ORIG_GETADDRINFO(host, port, family, type, proto, flags)
        return _ORIG_GETADDRINFO(host, port, family, type, proto, flags)

    socket.getaddrinfo = _getaddrinfo  # type: ignore[assignment]
    _PATCHED = True
