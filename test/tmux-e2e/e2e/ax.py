"""What AppleScript can't see, read through the Accessibility API.

Ghostty's scripting dictionary has no notion of overlays, alerts, notice
bars or menus; the Accessibility tree has all of them. Like the rest of the
harness this is addressed by **process id** (`AXUIElementCreateApplication`),
so it only ever touches the launched test instance.

Not System Events UI scripting: System Events turns element references back
into `application process "<name>"`, and the test instance's process has
the same name ("ghostty") as a Ghostty you may be running yourself. A click
through such a reference can land in your app.

Needs the Accessibility permission for the app running the harness (your
terminal). Without it every call raises `AxUnavailable`, a `Skip`.

The tree only holds windows on the active Space, so callers wait for a
window to show up (see `Context.ax_window`), activating the app meanwhile.
"""

from __future__ import annotations

from typing import Any, Iterator

from .util import Skip, log

try:
    import ApplicationServices as AS  # type: ignore[import-not-found]
except ImportError:  # pragma: no cover - only without the uv script deps
    AS = None


class AxUnavailable(Skip):
    """The Accessibility API is not permitted for this process."""


def _require() -> None:
    if AS is None:
        raise AxUnavailable("pyobjc ApplicationServices is not installed")
    if not AS.AXIsProcessTrusted():
        raise AxUnavailable(
            "the Accessibility permission is missing for the app running the harness "
            "(System Settings > Privacy & Security > Accessibility)"
        )


def _attr(element: Any, name: str) -> Any:
    err, value = AS.AXUIElementCopyAttributeValue(element, name, None)
    return value if err == 0 else None


def _children(element: Any) -> list[Any]:
    return list(_attr(element, "AXChildren") or [])


def _walk(element: Any, max_depth: int = 30, max_nodes: int = 5000) -> Iterator[Any]:
    """Every element under `element`, breadth first.

    Bounded, because the tree is not ours: a terminal can report deep or
    repeating structure, and a walk that never ends is worse than one
    that misses something at the bottom.
    """
    queue = [(element, 0)]
    seen = 0
    while queue and seen < max_nodes:
        e, depth = queue.pop(0)
        seen += 1
        yield e
        if depth < max_depth:
            queue.extend((c, depth + 1) for c in _children(e))


def _app(pid: int) -> Any:
    _require()
    return AS.AXUIElementCreateApplication(pid)


def windows(pid: int) -> dict[str, Any]:
    """`{title: element}` for the windows on the active Space."""
    return {str(_attr(w, "AXTitle") or ""): w for w in _attr(_app(pid), "AXWindows") or []}


def is_frontmost(pid: int) -> bool:
    """Whether the app is the active one (its menu bar is showing)."""
    return bool(_attr(_app(pid), "AXFrontmost"))


def window_names(pid: int) -> list[str]:
    return list(windows(pid))


def _texts(element: Any) -> list[str]:
    out = []
    for e in _walk(element):
        if _attr(e, "AXRole") == "AXStaticText":
            value = _attr(e, "AXValue") or _attr(e, "AXTitle") or _attr(e, "AXDescription")
            if isinstance(value, str) and value:
                out.append(value)
    return out


def window_texts(pid: int, window_name: str | None = None) -> list[str]:
    """Every static text in the app's windows (or in the one named so)."""
    wins = windows(pid)
    if window_name is not None:
        wins = {window_name: wins[window_name]} if window_name in wins else {}
    return [t for w in wins.values() for t in _texts(w)]


def sheet_texts(pid: int) -> list[list[str]]:
    """The static texts of each sheet (e.g. an NSAlert) on any window."""
    return [
        _texts(child)
        for w in windows(pid).values()
        for child in _children(w)
        if _attr(child, "AXRole") == "AXSheet"
    ]


def scroll_positions(pid: int, window_name: str) -> list[float]:
    """Where each terminal's vertical scroll bar in the named window is.

    0.0 is the top of the history and 1.0 the bottom (the live screen).
    The scroll bar is the native one around each surface, kept in sync
    with the viewport, so this is what a person sees, in any build.
    """
    wins = windows(pid)
    if window_name not in wins:
        raise RuntimeError(f"no window {window_name!r} (windows: {list(wins)})")
    out = []
    for area in _walk(wins[window_name]):
        if _attr(area, "AXRole") != "AXScrollArea":
            continue
        children = _children(area)
        if not any(_attr(c, "AXRole") == "AXTextArea" for c in children):
            continue
        for bar in children:
            if _attr(bar, "AXRole") == "AXScrollBar" and _attr(bar, "AXOrientation") == "AXVerticalOrientation":
                out.append(float(_attr(bar, "AXValue")))
    return out


def _press_in(root: Any, title: str) -> bool:
    for e in _walk(root):
        if _attr(e, "AXRole") == "AXButton" and title in (_attr(e, "AXTitle"), _attr(e, "AXDescription")):
            return AS.AXUIElementPerformAction(e, "AXPress") == 0
    return False


def press_button(pid: int, window_name: str, title: str) -> None:
    """Press the first button titled `title` anywhere in the named window."""
    wins = windows(pid)
    if window_name not in wins or not _press_in(wins[window_name], title):
        raise RuntimeError(f"no button {title!r} in window {window_name!r} (windows: {list(wins)})")
    log(f"pressed {title!r} in {window_name!r}")


def press_checkbox(pid: int, window_name: str, title: str) -> None:
    """Toggle the first checkbox (a SwiftUI `Toggle`) titled `title`."""
    wins = windows(pid)
    if window_name in wins:
        for e in _walk(wins[window_name]):
            if _attr(e, "AXRole") == "AXCheckBox" and title in (_attr(e, "AXTitle"), _attr(e, "AXDescription")):
                if AS.AXUIElementPerformAction(e, "AXPress") == 0:
                    log(f"toggled {title!r} in {window_name!r}")
                    return
    raise RuntimeError(f"no checkbox {title!r} in window {window_name!r} (windows: {list(wins)})")


def dismiss_sheets(pid: int, button: str = "OK") -> None:
    for w in windows(pid).values():
        for child in _children(w):
            if _attr(child, "AXRole") == "AXSheet":
                _press_in(child, button)


def _menu(parent: Any, title: str) -> Any:
    """The submenu of the item titled `title` in a menu bar or menu."""
    for item in _children(parent):
        if _attr(item, "AXTitle") == title:
            menus = [c for c in _children(item) if _attr(c, "AXRole") == "AXMenu"]
            if menus:
                return menus[0]
    raise RuntimeError(f"no menu {title!r}")


def menu_items(pid: int, *path: str) -> dict[str, bool]:
    """`{title: enabled}` for the items of a menu, e.g. ("File", "tmux").

    AppKit validates menu items only when their menu opens, so the menu is
    opened (and its submenus along `path`), read, and closed again.
    Reading it closed gives whatever was true the last time it opened.
    """
    import time

    bar = _attr(_app(pid), "AXMenuBar")
    top = next((i for i in _children(bar) if _attr(i, "AXTitle") == path[0]), None)
    if top is None:
        raise RuntimeError(f"no menu {path[0]!r}")
    AS.AXUIElementPerformAction(top, "AXPress")
    try:
        menu = _menu(bar, path[0])
        for title in path[1:]:
            item = next((i for i in _children(menu) if _attr(i, "AXTitle") == title), None)
            if item is None:
                raise RuntimeError(f"no menu item {title!r}")
            AS.AXUIElementPerformAction(item, "AXPress")
            time.sleep(0.2)
            menu = _menu(menu, title)
        time.sleep(0.2)
        return {
            str(_attr(item, "AXTitle")): bool(_attr(item, "AXEnabled"))
            for item in _children(menu)
            if _attr(item, "AXTitle")
        }
    finally:
        AS.AXUIElementPerformAction(top, "AXCancel")
        menu = _menu(bar, path[0])
        AS.AXUIElementPerformAction(menu, "AXCancel")


def set_window_size(pid: int, width: int, height: int) -> bool:
    """Resize the app's focused window. False if that isn't possible."""
    window = _attr(_app(pid), "AXFocusedWindow")
    if window is None:
        return False
    import Quartz  # type: ignore[import-not-found]

    size = AS.AXValueCreate(AS.kAXValueCGSizeType, Quartz.CGSizeMake(width, height))
    return AS.AXUIElementSetAttributeValue(window, "AXSize", size) == 0
