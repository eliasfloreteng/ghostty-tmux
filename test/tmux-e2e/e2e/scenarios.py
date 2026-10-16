"""The scenarios. Each is independent: fresh tmux server, fresh gateway window.

Scenarios prefixed `plumbing_` don't need tmux control-mode support in the
app; they validate the harness itself (isolated launch, AppleScript, input,
screen reading, private tmux socket) and should pass on any recent build.
"""

from __future__ import annotations

import secrets
from dataclasses import dataclass
from typing import Callable

from .context import SESSION, Context
from .util import Skip, check, log, wait_until
from .windows import native_windows, resize_front_window, screenshot


@dataclass(frozen=True)
class Scenario:
    name: str
    func: Callable[[Context], None]
    doc: str


SCENARIOS: list[Scenario] = []


def scenario(func: Callable[[Context], None]) -> Callable[[Context], None]:
    doc = (func.__doc__ or "").strip().splitlines()[0] if func.__doc__ else ""
    SCENARIOS.append(Scenario(func.__name__, func, doc))
    return func


def two_window_layout(ctx: Context) -> None:
    ctx.attach({"alpha": 1, "beta": 3})


# -- plumbing ----------------------------------------------------------------


@scenario
def plumbing_input_and_screen(ctx: Context) -> None:
    """Typing via `input text` reaches the shell and the screen can be read back."""
    gw = ctx.open_gateway()
    check(ctx.gateway_tty.startswith("/dev/"), f"gateway terminal has no tty: {ctx.gateway_tty!r}")
    ctx.app.type_line(gw, "echo e2e-$((6*7))")
    wait_until(
        lambda: "e2e-42" in ctx.app.read_screen(gw),
        timeout=ctx.timeout,
        desc="'e2e-42' on the gateway screen",
    )


@scenario
def plumbing_private_tmux_socket(ctx: Context) -> None:
    """A tmux command typed into Ghostty talks to the harness's private server."""
    gw = ctx.open_gateway()
    ctx.create_session()
    ctx.app.type_line(gw, ctx.tmux.shell_command("new-window", "-d", "-t", SESSION, "-n", "from-gateway"))
    wait_until(
        lambda: any(w.name == "from-gateway" for w in ctx.windows()),
        timeout=ctx.timeout,
        desc="tmux window 'from-gateway' created from inside Ghostty",
        describe_state=ctx.describe,
    )


@scenario
def plumbing_control_client_attaches(ctx: Context) -> None:
    """`tmux -CC attach` typed into the gateway registers a control-mode client."""
    ctx.attach(wait_gui=False)


# -- attach ------------------------------------------------------------------


@scenario
def attach_existing_layout(ctx: Context) -> None:
    """Attaching to 2 windows (1 + 3 panes) shows 2 tabs with 1 and 3 terminals."""
    two_window_layout(ctx)
    beta = ctx.tab_for_window("beta")
    check(len(beta.terminals) == 3, f"tab 'beta' has {len(beta.terminals)} terminals, expected 3")


# -- tmux -> GUI ---------------------------------------------------------------


@scenario
def tmux_new_window(ctx: Context) -> None:
    """`tmux new-window` adds a GUI tab."""
    ctx.attach()
    ctx.tmux.run("new-window", "-t", SESSION, "-n", "fresh")
    ctx.wait_synced("a GUI tab for the new tmux window")
    ctx.tab_for_window("fresh")


@scenario
def tmux_split_window(ctx: Context) -> None:
    """`tmux split-window` adds a terminal (split) to the tab."""
    ctx.attach()
    ctx.tmux.run("split-window", "-h", "-t", f"{SESSION}:main")
    ctx.wait_synced("a GUI split for the new tmux pane")


@scenario
def tmux_kill_pane(ctx: Context) -> None:
    """`tmux kill-pane` removes the corresponding split."""
    two_window_layout(ctx)
    pane = ctx.tmux.window(SESSION, "beta").panes[1]
    ctx.tmux.run("kill-pane", "-t", pane.id)
    ctx.wait_synced("the split of the killed pane to close")


@scenario
def tmux_kill_window(ctx: Context) -> None:
    """`tmux kill-window` closes the corresponding tab."""
    two_window_layout(ctx)
    ctx.tmux.run("kill-window", "-t", f"{SESSION}:beta")
    ctx.wait_synced("the tab of the killed window to close")


@scenario
def tmux_rename_window(ctx: Context) -> None:
    """`tmux rename-window` updates the tab title."""
    two_window_layout(ctx)
    ctx.tmux.run("rename-window", "-t", f"{SESSION}:beta", "gamma")
    ctx.wait_synced("the tab title to follow rename-window")


@scenario
def tmux_select_window(ctx: Context) -> None:
    """`tmux select-window` selects the corresponding tab."""
    two_window_layout(ctx)
    ctx.tmux.run("select-window", "-t", f"{SESSION}:beta")
    wait_until(
        lambda: ctx.tab_for_window("beta").selected,
        timeout=ctx.timeout,
        desc="tab 'beta' to become selected",
        describe_state=ctx.describe,
    )


@scenario
def tmux_select_pane(ctx: Context) -> None:
    """`tmux select-pane` moves GUI focus to the corresponding split."""
    two_window_layout(ctx)
    ctx.tmux.run("select-window", "-t", f"{SESSION}:beta")
    tab = ctx.tab_for_window("beta")
    mapping = ctx.pane_map(tab)
    for term_id, pane_id in mapping.items():
        ctx.tmux.run("select-pane", "-t", pane_id)
        wait_until(
            lambda: ctx.tab_for_window("beta").focused_terminal == term_id,
            timeout=ctx.timeout,
            desc=f"GUI focus to follow select-pane {pane_id}",
            describe_state=ctx.describe,
        )


@scenario
def tmux_zoom_pane(ctx: Context) -> None:
    """`tmux resize-pane -Z` zooms the split (screenshot; verify manually)."""
    two_window_layout(ctx)
    ctx.tmux.run("select-window", "-t", f"{SESSION}:beta")
    ctx.tmux.run("resize-pane", "-Z", "-t", ctx.tmux.window(SESSION, "beta").panes[0].id)
    check(ctx.tmux.window(SESSION, "beta").zoomed, "tmux did not report the window as zoomed")
    # Zoom stays structurally identical (all terminals still exist), and the
    # AppleScript dictionary exposes no zoom state or terminal geometry.
    ctx.wait_synced()
    shots = screenshot(ctx.app.pid, ctx.out_dir, "tmux_zoom_pane-zoomed")
    raise Skip(f"zoom state is not observable via AppleScript; inspect {', '.join(map(str, shots))}")


# -- GUI -> tmux ---------------------------------------------------------------


@scenario
def gui_input_text(ctx: Context) -> None:
    """`input text` into a tmux terminal arrives in the tmux pane."""
    two_window_layout(ctx)
    tab = ctx.tab_for_window("beta")
    mapping = ctx.pane_map(tab)
    term_id, pane_id = list(mapping.items())[-1]
    token = secrets.token_hex(3)
    ctx.app.type_line(term_id, f"echo typed-{token}-$((2+3))")
    wait_until(
        lambda: f"typed-{token}-5" in ctx.tmux.capture(pane_id),
        timeout=ctx.timeout,
        desc=f"command output in tmux pane {pane_id}",
        describe_state=lambda: ctx.tmux.capture(pane_id).strip()[-300:],
    )


@scenario
def gui_new_tab(ctx: Context) -> None:
    """The `new_tab` action on a tmux terminal creates a tmux window."""
    ctx.attach()
    term = ctx.tab_for_window("main").terminals[0]
    ctx.app.perform(term.id, "new_tab")
    wait_until(
        lambda: len(ctx.windows()) == 2,
        timeout=ctx.timeout,
        desc="a second tmux window",
        describe_state=ctx.describe,
    )
    ctx.wait_synced()


@scenario
def gui_new_split(ctx: Context) -> None:
    """The `new_split:right` action creates a tmux pane."""
    ctx.attach()
    term = ctx.tab_for_window("main").terminals[0]
    ctx.app.perform(term.id, "new_split:right")
    wait_until(
        lambda: len(ctx.tmux.window(SESSION, "main").panes) == 2,
        timeout=ctx.timeout,
        desc="a second pane in tmux window 'main'",
        describe_state=ctx.describe,
    )
    ctx.wait_synced()


@scenario
def gui_close_surface(ctx: Context) -> None:
    """Closing a split kills its tmux pane."""
    two_window_layout(ctx)
    tab = ctx.tab_for_window("beta")
    mapping = ctx.pane_map(tab)
    term_id, pane_id = next(iter(mapping.items()))
    ctx.app.close(term_id)
    wait_until(
        lambda: pane_id not in {p.id for p in ctx.tmux.window(SESSION, "beta").panes},
        timeout=ctx.timeout,
        desc=f"tmux pane {pane_id} to be killed",
        describe_state=ctx.describe,
    )
    ctx.wait_synced()


@scenario
def gui_close_tab(ctx: Context) -> None:
    """Closing a tab kills its tmux window."""
    two_window_layout(ctx)
    ctx.app.close_tab(ctx.tab_for_window("beta"))
    wait_until(
        lambda: [w.name for w in ctx.windows()] == ["alpha"],
        timeout=ctx.timeout,
        desc="tmux window 'beta' to be killed",
        describe_state=ctx.describe,
    )
    ctx.wait_synced()


@scenario
def gui_select_tab(ctx: Context) -> None:
    """Selecting a tab selects the tmux window."""
    two_window_layout(ctx)
    ctx.app.select_tab(ctx.tab_for_window("beta"))
    wait_until(
        lambda: ctx.tmux.window(SESSION, "beta").active,
        timeout=ctx.timeout,
        desc="tmux window 'beta' to become active",
        describe_state=ctx.describe,
    )


@scenario
def gui_focus_terminal(ctx: Context) -> None:
    """Focusing a split selects the tmux pane."""
    two_window_layout(ctx)
    ctx.tmux.run("select-window", "-t", f"{SESSION}:beta")
    mapping = ctx.pane_map(ctx.tab_for_window("beta"))
    for term_id, pane_id in mapping.items():
        ctx.app.focus(term_id)
        wait_until(
            lambda: ctx.active_pane("beta") == pane_id,
            timeout=ctx.timeout,
            desc=f"tmux pane {pane_id} to become active",
            describe_state=ctx.describe,
        )


@scenario
def gui_zoom(ctx: Context) -> None:
    """The `toggle_split_zoom` action zooms the tmux pane (resize-pane -Z)."""
    two_window_layout(ctx)
    ctx.tmux.run("select-window", "-t", f"{SESSION}:beta")
    mapping = ctx.pane_map(ctx.tab_for_window("beta"))
    term_id, pane_id = list(mapping.items())[1]
    ctx.app.perform(term_id, "toggle_split_zoom")
    wait_until(
        lambda: ctx.tmux.window(SESSION, "beta").zoomed and ctx.active_pane("beta") == pane_id,
        timeout=ctx.timeout,
        desc=f"tmux window 'beta' zoomed on {pane_id}",
        describe_state=ctx.describe,
    )
    ctx.app.perform(term_id, "toggle_split_zoom")
    wait_until(
        lambda: not ctx.tmux.window(SESSION, "beta").zoomed,
        timeout=ctx.timeout,
        desc="tmux window 'beta' to unzoom",
        describe_state=ctx.describe,
    )


@scenario
def gui_rename_tab(ctx: Context) -> None:
    """Renaming a tab renames the tmux window (not scriptable; manual)."""
    raise Skip(
        "Ghostty has no non-interactive rename action (only prompt_tab_title, which opens a dialog); "
        "verify manually: rename a tmux tab and check `tmux list-windows`"
    )


# -- content -------------------------------------------------------------------


@scenario
def pane_output_visible(ctx: Context) -> None:
    """Output produced in a tmux pane becomes visible in the GUI terminal."""
    ctx.attach()
    term = ctx.tab_for_window("main").terminals[0]
    token = f"hello-e2e-{secrets.token_hex(3)}"
    ctx.tmux.run("send-keys", "-t", f"{SESSION}:main", f"printf '%s\\n' {token}", "Enter")
    wait_until(
        lambda: f"\n{token}" in "\n" + ctx.app.read_screen(term.id),
        timeout=ctx.timeout,
        desc=f"{token!r} on the GUI terminal's screen",
        describe_state=lambda: repr(ctx.app.read_screen(term.id).strip()[-300:]),
    )


# -- lifecycle -----------------------------------------------------------------


def expect_gateway_back(ctx: Context, why: str) -> None:
    """After control mode ends: tmux tabs gone, app alive, gateway usable."""
    wait_until(
        lambda: not ctx.tmux_tabs(),
        timeout=ctx.timeout,
        desc=f"tmux tabs to close after {why}",
        describe_state=ctx.describe,
    )
    check(ctx.app.alive(), f"Ghostty exited after {why}")
    gateway = next((t for t in ctx.app.snapshot().terminals if t.id == ctx.gateway), None)
    check(gateway is not None, f"the gateway terminal is gone after {why}{ctx.describe()}")
    ctx.app.type_line(ctx.gateway, "echo back-$((40+2))")
    wait_until(
        lambda: "back-42" in ctx.app.read_screen(ctx.gateway),
        timeout=ctx.timeout,
        desc=f"the gateway shell to respond after {why}",
    )


@scenario
def detach_client(ctx: Context) -> None:
    """`tmux detach-client` closes tmux tabs; the gateway shell comes back."""
    two_window_layout(ctx)
    for client in ctx.tmux.control_clients():
        ctx.tmux.run("detach-client", "-t", client)
    expect_gateway_back(ctx, "detach-client")
    check(ctx.tmux.alive(), "tmux server should survive a detach")


@scenario
def server_exit(ctx: Context) -> None:
    """`tmux kill-server` closes tmux tabs without crashing Ghostty."""
    two_window_layout(ctx)
    ctx.tmux.kill_server()
    expect_gateway_back(ctx, "kill-server")


# -- resize --------------------------------------------------------------------


@scenario
def resize_window(ctx: Context) -> None:
    """Resizing the GUI changes the tmux window size."""
    ctx.attach()
    tab = ctx.tab_for_window("main")

    def size() -> tuple[int, int]:
        w = ctx.tmux.window(SESSION, "main")
        return (w.width, w.height)

    before = size()
    ctx.app.select_tab(tab)
    native = [w for w in native_windows(ctx.app.pid) if w.onscreen]
    if native and resize_front_window(ctx.app.pid, native[0].width + 300, native[0].height + 200):
        method = "growing the window via System Events"
    else:
        # No Accessibility permission: shrink the font instead, which grows
        # the grid without touching the window frame.
        method = "decrease_font_size"
        ctx.app.perform(tab.terminals[0].id, "decrease_font_size:4")
    log(f"resizing by {method}")

    wait_until(
        lambda: size()[0] > before[0] or size()[1] > before[1],
        timeout=ctx.timeout,
        desc=f"tmux window to grow from {before[0]}x{before[1]} after {method}",
        describe_state=lambda: f"now {'x'.join(map(str, size()))}{ctx.describe()}",
    )
