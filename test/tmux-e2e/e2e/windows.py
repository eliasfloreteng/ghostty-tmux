"""Native window geometry and screenshots via CoreGraphics / screencapture.

AppleScript doesn't expose window bounds, so the CoreGraphics window list is
used for sizes and for the window ids `screencapture -l` needs.
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path

from .util import log

try:
    import Quartz  # type: ignore[import-not-found]
except ImportError:  # pragma: no cover - only without the uv script deps
    Quartz = None


@dataclass(frozen=True)
class NativeWindow:
    number: int
    title: str
    x: int
    y: int
    width: int
    height: int
    onscreen: bool


def native_windows(pid: int) -> list[NativeWindow]:
    """Normal-layer windows owned by `pid`, front to back."""
    if Quartz is None:
        return []
    infos = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID) or []
    result = []
    for info in infos:
        if info.get("kCGWindowOwnerPID") != pid or info.get("kCGWindowLayer", 0) != 0:
            continue
        b = info.get("kCGWindowBounds", {})
        if b.get("Height", 0) < 50:  # skip tab-bar/accessory slivers
            continue
        result.append(
            NativeWindow(
                number=int(info["kCGWindowNumber"]),
                title=str(info.get("kCGWindowName", "") or ""),
                x=int(b.get("X", 0)),
                y=int(b.get("Y", 0)),
                width=int(b.get("Width", 0)),
                height=int(b.get("Height", 0)),
                onscreen=bool(info.get("kCGWindowIsOnscreen", False)),
            )
        )
    return result


def screenshot(pid: int, out_dir: Path, stem: str) -> list[Path]:
    """Capture every on-screen window of `pid`; fall back to the full screen.

    Requires the Screen Recording permission for the invoking terminal;
    without it macOS silently returns only the desktop/wallpaper.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    paths = []
    windows = [w for w in native_windows(pid) if w.onscreen]
    for i, w in enumerate(windows):
        path = out_dir / f"{stem}-{i}.png"
        if (
            subprocess.run(
                ["screencapture", "-x", "-o", "-l", str(w.number), str(path)], capture_output=True
            ).returncode
            == 0
        ):
            paths.append(path)
    if not paths:
        path = out_dir / f"{stem}-screen.png"
        if subprocess.run(["screencapture", "-x", str(path)], capture_output=True).returncode == 0:
            paths.append(path)
    log(f"screenshots: {', '.join(map(str, paths)) or 'none'}")
    return paths


def resize_front_window(pid: int, width: int, height: int) -> bool:
    """Resize the focused window of `pid` through the Accessibility API.

    Needs the Accessibility permission for the invoking terminal. Returns
    False (rather than raising) when that isn't available.
    """
    from . import ax

    try:
        ok = ax.set_window_size(pid, width, height)
    except ax.AxUnavailable as exc:
        log(f"resize via Accessibility unavailable: {exc}")
        return False
    if not ok:
        log("resize via Accessibility failed")
    return ok
