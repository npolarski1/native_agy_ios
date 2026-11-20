"""Test package bootstrap ensuring `antigravity_bridge` is importable without installation."""

from __future__ import annotations

import sys
from pathlib import Path

_BRIDGE_ROOT = str(Path(__file__).resolve().parent.parent)
if _BRIDGE_ROOT not in sys.path:
    sys.path.insert(0, _BRIDGE_ROOT)
