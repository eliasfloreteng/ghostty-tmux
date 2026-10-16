"""Per-scenario fixture tying the Ghostty instance and the tmux server together.

The harness is deliberately implementation-agnostic. The contract it checks
(see README.md) is only:

* the terminal in which `tmux -CC` runs is the *gateway*; every other GUI tab
  belongs to tmux,
* one tmux window == one GUI tab, one tmux pane == one GUI terminal in it,
* the tab name is the tmux window name,
* the tab's selected/focused state mirrors the active window/pane.

GUI terminals are correlated with tmux panes by typing a unique marker into
each terminal and looking for it with `capture-pane`, so no knowledge of the
implementation's internal ids is needed.
"""

from __future__ import annotations

import secrets
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

from .ghostty import GhosttyApp, Snapshot, Tab
from .tmux import Tmux, Window
from .util import CheckFailed, check, log, wait_until

SESSION = "e2e"


@dataclass
class Context:
    app: GhosttyApp
    tmux: Tmux
    out_dir: Path
    timeout: float
    gateway: str = ""  # terminal id of the gateway terminal
    gateway_tty: str = ""

    # -- setup --------------------------------------------------------------

    def open_gateway(self) -> str:
        """Open a fresh Ghostty window running the plain test shell."""
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
        self.gateway = self.gateway_tty = ""

    # -- GUI <-> tmux comparison -------------------------------------------

    def tmux_tabs(self, snap: Snapshot | None = None) -> list[Tab]:
        """GUI tabs that represent tmux windows (everything but the gateway)."""
        snap = snap or self.app.snapshot()
        return [t for t in snap.tabs if all(x.id != self.gateway for x in t.terminals)]

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

    def active_pane(self, window_name: str) -> str:
        w = self.tmux.window(SESSION, window_name)
        active = [p.id for p in w.panes if p.active]
        if len(active) != 1:
            raise CheckFailed(f"tmux window {window_name!r} has {len(active)} active panes")
        return active[0]
