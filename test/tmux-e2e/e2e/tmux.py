"""Ground truth: talk to the private tmux server over its own socket."""

from __future__ import annotations

import os
import secrets
import shlex
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .util import HarnessError, log

# Panes run a plain POSIX shell with a fixed prompt so screen contents are
# predictable and the user's shell rc files don't get involved. Window names
# are pinned (no automatic-rename) so scenarios can identify windows by name.
TMUX_CONF = """\
set -g default-command "env -i HOME={home} PATH=/usr/bin:/bin PS1='$ ' TERM=xterm-256color /bin/sh"
set -g automatic-rename off
set -g allow-rename off
set -g history-limit 2000
set -g exit-empty on
"""


@dataclass(frozen=True)
class Pane:
    id: str  # e.g. "%3"
    window_id: str  # e.g. "@1"
    index: int
    active: bool
    width: int
    height: int


@dataclass(frozen=True)
class Window:
    id: str  # e.g. "@1"
    index: int
    name: str
    active: bool
    zoomed: bool
    width: int
    height: int
    panes: tuple[Pane, ...]


class Tmux:
    """A tmux server on a private, randomly named socket (`tmux -L`)."""

    def __init__(self, workdir: Path, binary: str | None = None) -> None:
        self.binary = binary or shutil.which("tmux") or ""
        if not self.binary:
            raise HarnessError("tmux not found in PATH")
        self.socket = f"ghostty-e2e-{secrets.token_hex(4)}"
        self.conf = workdir / "tmux.conf"
        self.conf.write_text(TMUX_CONF.format(home=shlex.quote(str(Path.home()))))
        # Never let a surrounding tmux session leak into ours.
        self.env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE")}

    def add_config(self, text: str) -> None:
        """Append lines to the server's config. Only before the server starts."""
        with self.conf.open("a") as f:
            f.write(text.rstrip("\n") + "\n")

    # -- invocation ---------------------------------------------------------

    @property
    def base_argv(self) -> list[str]:
        return [self.binary, "-L", self.socket, "-f", str(self.conf)]

    def shell_command(self, *args: str) -> str:
        """The command line a user would type to run tmux against our server."""
        return shlex.join([*self.base_argv, *args])

    def run(self, *args: str, check: bool = True) -> str:
        argv = [*self.base_argv, *args]
        log(f"tmux {' '.join(args)}")
        proc = subprocess.run(argv, capture_output=True, text=True, env=self.env, timeout=10)
        if check and proc.returncode != 0:
            raise RuntimeError(f"tmux {' '.join(args)} failed ({proc.returncode}): {proc.stderr.strip()}")
        return proc.stdout

    def alive(self) -> bool:
        proc = subprocess.run([*self.base_argv, "list-sessions"], capture_output=True, env=self.env, timeout=10)
        return proc.returncode == 0

    @property
    def socket_path(self) -> Path:
        base = Path(self.env.get("TMUX_TMPDIR") or "/tmp")
        return base / f"tmux-{os.getuid()}" / self.socket

    def kill_server(self) -> None:
        subprocess.run([*self.base_argv, "kill-server"], capture_output=True, env=self.env, timeout=10)
        # tmux doesn't always remove the socket file on kill-server.
        self.socket_path.unlink(missing_ok=True)

    # -- queries ------------------------------------------------------------

    def windows(self, session: str) -> list[Window]:
        wfmt = "#{window_id}\t#{window_index}\t#{window_active}\t#{window_zoomed_flag}\t#{window_width}\t#{window_height}\t#{window_name}"
        pfmt = "#{window_id}\t#{pane_id}\t#{pane_index}\t#{pane_active}\t#{pane_width}\t#{pane_height}"
        panes: dict[str, list[Pane]] = {}
        for line in self.run("list-panes", "-s", "-t", session, "-F", pfmt).splitlines():
            wid, pid, idx, active, w, h = line.split("\t")
            panes.setdefault(wid, []).append(Pane(pid, wid, int(idx), active == "1", int(w), int(h)))
        result = []
        for line in self.run("list-windows", "-t", session, "-F", wfmt).splitlines():
            wid, idx, active, zoomed, w, h, name = line.split("\t", 6)
            result.append(
                Window(wid, int(idx), name, active == "1", zoomed == "1", int(w), int(h), tuple(panes.get(wid, ())))
            )
        return result

    def window(self, session: str, name: str) -> Window:
        for w in self.windows(session):
            if w.name == name:
                return w
        raise KeyError(f"no tmux window named {name!r}")

    def clients(self) -> list[str]:
        out = self.run("list-clients", "-F", "#{client_name}\t#{client_control_mode}", check=False)
        return [line for line in out.splitlines() if line.strip()]

    def control_clients(self) -> list[str]:
        return [c.split("\t")[0] for c in self.clients() if c.endswith("\t1")]

    def capture(self, target: str) -> str:
        return self.run("capture-pane", "-p", "-J", "-t", target)

    def capture_all(self, target: str) -> str:
        """The pane's history and screen, as `capture-pane -S -` sees them."""
        return self.run("capture-pane", "-p", "-J", "-S", "-", "-t", target)

    def client_session(self, client: str) -> str:
        return self.run("display-message", "-p", "-c", client, "#{client_session}").strip()

    def describe(self, session: str) -> str:
        try:
            ws = self.windows(session)
        except Exception as exc:  # noqa: BLE001
            return f"<tmux unavailable: {exc}>"
        parts = []
        for w in ws:
            flags = ("*" if w.active else "") + ("Z" if w.zoomed else "")
            panes = ",".join(p.id + ("*" if p.active else "") for p in w.panes)
            parts.append(f"{w.id}:{w.name}{flags} {w.width}x{w.height} [{panes}]")
        return "; ".join(parts) or "<no windows>"
