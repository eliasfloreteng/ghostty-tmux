"""Per-scenario fixture tying the Ghostty instance and the tmux server together.

The harness is deliberately implementation-agnostic. The contract it checks
(see README.md) is only:

* the terminal in which `tmux -CC` runs is the *gateway*; every other GUI tab
  belongs to tmux,
* one tmux window == one GUI tab, one tmux pane == one GUI terminal in it,
* a tab is titled like its active pane (see `tmux_tabs` for how tabs are
  told apart all the same),
* the tab's selected/focused state mirrors the active window/pane.

GUI terminals are correlated with tmux panes by typing a unique marker into
each terminal and looking for it with `capture-pane`, so no knowledge of the
implementation's internal ids is needed.
"""

from __future__ import annotations

import secrets
from collections import Counter
from dataclasses import dataclass, field, replace
from pathlib import Path

from . import ax
from .ghostty import GhosttyApp, Snapshot, Tab
from .tmux import Tmux, Window
from .util import CheckFailed, check, log, wait_until

SESSION = "e2e"

# What a tab shows in front of its title for tmux's window flags.
ALERT_MARKS = {"bell": "🔔", "activity": "•", "silence": "💤"}


def unmarked(title: str) -> str:
    """A tab's title without the alert marks in front of it."""
    head, _, rest = title.partition(" ")
    if rest and head and all(c in "".join(ALERT_MARKS.values()) for c in head):
        return rest
    return title


@dataclass
class Context:
    app: GhosttyApp
    tmux: Tmux
    out_dir: Path
    timeout: float
    gateway: str = ""  # terminal id of the gateway terminal
    gateway_tty: str = ""
    gateway_title: str = ""  # the gateway window's title before attaching
    # GUI tab id -> the id of the tmux window it was found to show.
    tab_windows: dict[str, str] = field(default_factory=dict)

    # -- setup --------------------------------------------------------------

    def open_gateway(self) -> str:
        """Open a fresh Ghostty window running the plain test shell."""
        # Focus decides which pane tmux has active, so the app has to be
        # the active one, not merely have its windows on screen.
        self.app.activate()
        self.app.new_window()
        snap = wait_until(
            lambda: (s := self.app.snapshot()).terminals and s,
            timeout=self.timeout,
            desc="gateway window to open",
        )
        term = snap.terminals[0]
        self.gateway, self.gateway_tty = term.id, term.tty
        # Wait for the shell prompt so typed input isn't lost.
        wait_until(
            lambda: "gateway$" in self.app.read_screen(self.gateway),
            timeout=self.timeout,
            desc="gateway shell prompt",
        )
        log(f"gateway terminal {self.gateway} on {self.gateway_tty}")
        return self.gateway

    def create_session(self, layout: dict[str, int] | None = None) -> None:
        """Create the tmux session (detached) with `{window name: pane count}`."""
        layout = layout or {"main": 1}
        names = list(layout)
        self.tmux.run("new-session", "-d", "-s", SESSION, "-n", names[0], "-x", "110", "-y", "30")
        for name in names[1:]:
            self.tmux.run("new-window", "-d", "-t", SESSION, "-n", name)
        for name, panes in layout.items():
            for _ in range(panes - 1):
                self.tmux.run("split-window", "-d", "-t", f"{SESSION}:{name}")
            self.tmux.run("select-layout", "-t", f"{SESSION}:{name}", "tiled")
        self.tmux.run("select-window", "-t", f"{SESSION}:{names[0]}")

    def attach(self, layout: dict[str, int] | None = None, wait_gui: bool = True) -> None:
        """Create the session and attach to it in control mode from the gateway."""
        if not self.gateway:
            self.open_gateway()
        self.create_session(layout)
        self.attach_session(wait_gui=wait_gui)

    def attach_session(self, wait_gui: bool = True) -> None:
        """Attach the gateway, in control mode, to the session already there."""
        if not self.gateway:
            self.open_gateway()
        self.gateway_title = self.gateway_window_name()
        self.app.type_line(self.gateway, self.tmux.shell_command("-CC", "attach-session", "-t", SESSION))
        wait_until(
            self.tmux.control_clients,
            timeout=self.timeout,
            desc="a tmux control-mode client to attach (typed into the gateway terminal)",
            describe_state=lambda: f"tmux clients: {self.tmux.clients()}",
        )
        if wait_gui:
            self.wait_synced("GUI to mirror the tmux session after attach")

    def teardown(self) -> None:
        self.tmux.kill_server()
        if self.app.alive():
            self.app.close_all_windows(timeout=self.timeout)
        self.gateway = self.gateway_tty = self.gateway_title = ""
        self.tab_windows.clear()

    # -- GUI <-> tmux comparison -------------------------------------------

    def tmux_tabs(self, snap: Snapshot | None = None) -> list[Tab]:
        """GUI tabs that represent tmux windows (everything but the gateway).

        Each is named after the tmux window it shows, its title kept in
        `title`. A tab is titled like its active pane, not after its
        window, so which window a tab shows is worked out the first time
        it is seen and remembered by the tab's id: by the title the tmux
        config gives a new window's pane, the window's name, or failing
        that by being the only new tab when there is only one new window.
        A tab not worked out yet keeps its title as its name.
        """
        snap = snap or self.app.snapshot()
        tabs = [t for t in snap.tabs if all(x.id != self.gateway for x in t.terminals)]
        try:
            windows = {w.id: w for w in self.windows()}
        except Exception:  # noqa: BLE001 - no server or no session
            windows = {}

        live = {t.id for t in tabs}
        self.tab_windows = {t: w for t, w in self.tab_windows.items() if t in live and w in windows}
        taken = set(self.tab_windows.values())
        unknown = [t for t in tabs if t.id not in self.tab_windows]
        for t in unknown:
            title = unmarked(t.name)
            found = [w for w in windows.values() if w.name == title and w.id not in taken]
            if len(found) == 1:
                self.tab_windows[t.id] = found[0].id
                taken.add(found[0].id)
        unknown = [t for t in tabs if t.id not in self.tab_windows]
        free = [w for w in windows if w not in taken]
        if len(unknown) == 1 and len(free) == 1:
            self.tab_windows[unknown[0].id] = free[0]

        def named(t: Tab) -> Tab:
            window = windows.get(self.tab_windows.get(t.id, ""))
            return replace(t, name=window.name if window else t.name, title=t.name)

        return [named(t) for t in tabs]

    def windows(self) -> list[Window]:
        return self.tmux.windows(SESSION)

    def describe(self) -> str:
        try:
            gui = self.app.snapshot().describe()
        except Exception as exc:  # noqa: BLE001
            gui = f"<unavailable: {exc}>"
        return f"\n    gui:  {gui}\n    tmux: {self.tmux.describe(SESSION)}"

    def structure_mismatch(self) -> str | None:
        """Why the GUI structure differs from tmux, or None if it matches."""
        tabs = self.tmux_tabs()
        wins = self.windows()
        if len(tabs) != len(wins):
            return f"{len(tabs)} tmux GUI tabs vs {len(wins)} tmux windows"
        gui_counts = Counter(len(t.terminals) for t in tabs)
        tmux_counts = Counter(len(w.panes) for w in wins)
        if gui_counts != tmux_counts:
            return f"terminals per tab {sorted(gui_counts.elements())} vs panes per window {sorted(tmux_counts.elements())}"
        gui_names = Counter(t.name for t in tabs)
        tmux_names = Counter(w.name for w in wins)
        if gui_names != tmux_names:
            return f"tab names {sorted(gui_names)} vs window names {sorted(tmux_names)}"
        return None

    def wait_synced(self, desc: str = "GUI to mirror tmux") -> None:
        last = {"why": ""}

        def synced() -> bool:
            why = self.structure_mismatch()
            last["why"] = why or ""
            return why is None

        wait_until(
            synced,
            timeout=self.timeout,
            desc=desc,
            describe_state=lambda: f"{last['why']}{self.describe()}",
        )

    def tab_for_window(self, name: str) -> Tab:
        """The GUI tab mirroring the tmux window `name` (matched by name)."""
        return wait_until(
            lambda: next((t for t in self.tmux_tabs() if t.name == name), None),
            timeout=self.timeout,
            desc=f"a GUI tab named {name!r}",
            describe_state=self.describe,
        )

    def pane_map(self, tab: Tab) -> dict[str, str]:
        """Map each GUI terminal id in `tab` to the tmux pane id it shows.

        Types a unique marker (without Enter) into every terminal and finds
        the pane whose screen shows it, then clears the line again.
        """
        window = next((w for w in self.windows() if w.name == tab.name), None)
        check(window is not None, f"no tmux window named {tab.name!r}{self.describe()}")
        mapping: dict[str, str] = {}
        for term in tab.terminals:
            marker = f"e2e-mark-{secrets.token_hex(3)}"
            self.app.input_text(term.id, marker)

            def find() -> str | None:
                for pane in window.panes:
                    if marker in self.tmux.capture(pane.id):
                        return pane.id
                return None

            pane_id = wait_until(
                find,
                timeout=self.timeout,
                desc=f"marker typed into GUI terminal {term.id[:8]} to show up in a pane of tmux window {tab.name!r}",
                describe_state=self.describe,
            )
            self.tmux.run("send-keys", "-t", pane_id, "C-u")
            mapping[term.id] = pane_id
        log(f"pane map for {tab.name!r}: {mapping}")
        return mapping

    def gateway_window_name(self) -> str:
        """The title of the GUI window holding the gateway terminal."""
        for w in self.app.snapshot().windows:
            if any(x.id == self.gateway for t in w.tabs for x in t.terminals):
                return w.name
        raise CheckFailed(f"no window holds the gateway{self.describe()}")

    def front_window(self) -> str:
        """The name of the frontmost GUI window (AppleScript lists them front to back)."""
        windows = self.app.snapshot().windows
        check(windows, "Ghostty has no windows")
        return windows[0].name

    def terminal_for_pane(self, pane_id: str) -> str:
        """The GUI terminal showing tmux pane `pane_id`."""
        pane = next((p for w in self.windows() for p in w.panes if p.id == pane_id), None)
        check(pane is not None, f"no tmux pane {pane_id}{self.describe()}")
        window = next(w for w in self.windows() if w.id == pane.window_id)
        mapping = self.pane_map(self.tab_for_window(window.name))
        return next(t for t, p in mapping.items() if p == pane_id)

    def ax_window(self, name: str) -> str:
        """Wait until UI scripting can see the window `name`, and return it.

        UI scripting only sees windows on the active Space, so this keeps
        activating the app until the window shows up there.
        """

        def visible() -> bool:
            if name in ax.window_names(self.app.pid):
                return True
            self.app.activate()
            return False

        wait_until(visible, timeout=self.timeout, desc=f"window {name!r} to be visible to UI scripting")
        return name

    def active_pane(self, window_name: str) -> str:
        w = self.tmux.window(SESSION, window_name)
        active = [p.id for p in w.panes if p.active]
        if len(active) != 1:
            raise CheckFailed(f"tmux window {window_name!r} has {len(active)} active panes")
        return active[0]
