"""Shared text-console setup for the executable Linux capture tools."""

import sys


def configure_utf8_stdio() -> None:
    """Keep Unicode diagnostics printable when the host defaults to a legacy code page."""
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if callable(reconfigure):
            reconfigure(encoding="utf-8")
