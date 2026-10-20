"""The scenarios. Each is independent: fresh tmux server, fresh gateway window.

Scenarios prefixed `plumbing_` don't need tmux control-mode support in the
app; they validate the harness itself (isolated launch, AppleScript, input,
screen reading, private tmux socket) and should pass on any recent build.
"""

from __future__ import annotations

import base64
import re
import secrets
import time
from dataclasses import dataclass
from typing import Callable

from . import ax
from .context import SESSION, Context
from .ghostty import AppleScriptError, pbcopy, pbpaste
from .util import CheckFailed, Skip, check, log, wait_until
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


def enter_session(ctx: Context) -> None:
    """Put the user in a tmux tab, as they would be when the session ends."""
    ctx.app.focus(ctx.tmux_tabs()[0].terminals[0].id)
    wait_until(
        lambda: ctx.front_window() != ctx.gateway_window_name(),
        timeout=ctx.timeout,
        desc="a tmux tab to come to the front",
        describe_state=ctx.describe,
    )


def expect_gateway_back(ctx: Context, why: str) -> None:
    """After control mode ends: tmux tabs gone without asking, app alive,
    the gateway in front with its title back, and usable.

    No reason bar is expected: tmux (3.6) ends a session it detached,
    killed or lost with a bare `%exit`, and the app shows one only for the
    reason `%exit` carries.
    """
    wait_until(
        lambda: not ctx.tmux_tabs(),
        timeout=ctx.timeout,
        desc=f"tmux tabs to close after {why}",
        describe_state=ctx.describe,
    )
    check(ctx.app.alive(), f"Ghostty exited after {why}")
    gateway = next((t for t in ctx.app.snapshot().terminals if t.id == ctx.gateway), None)
    check(gateway is not None, f"the gateway terminal is gone after {why}{ctx.describe()}")

    # Closing tmux's windows is not the user closing anything: no
    # confirmation may be left up anywhere.
    try:
        sheets = ax.sheet_texts(ctx.app.pid)
        check(not sheets, f"a sheet is up after {why}: {sheets}")
    except ax.AxUnavailable as exc:
        log(f"not checking for prompts: {exc}")

    wait_until(
        lambda: ctx.front_window() == ctx.gateway_window_name(),
        timeout=ctx.timeout,
        desc=f"the gateway window to come to the front after {why}",
        describe_state=ctx.describe,
    )
    wait_until(
        lambda: ctx.gateway_window_name() == ctx.gateway_title,
        timeout=ctx.timeout,
        desc=f"the gateway title to go back to {ctx.gateway_title!r} after {why}",
        describe_state=lambda: f"title {ctx.gateway_window_name()!r}",
    )
    ctx.app.type_line(ctx.gateway, "echo back-$((40+2))")
    wait_until(
        lambda: "back-42" in ctx.app.read_screen(ctx.gateway),
        timeout=ctx.timeout,
        desc=f"the gateway shell to respond after {why}",
    )


@scenario
def detach_client(ctx: Context) -> None:
    """`tmux detach-client` closes tmux tabs; the gateway comes back to the front."""
    two_window_layout(ctx)
    enter_session(ctx)
    for client in ctx.tmux.control_clients():
        ctx.tmux.run("detach-client", "-t", client)
    expect_gateway_back(ctx, "detach-client")
    check(ctx.tmux.alive(), "tmux server should survive a detach")


@scenario
def kill_session(ctx: Context) -> None:
    """`tmux kill-session` closes tmux tabs; the gateway comes back to the front."""
    two_window_layout(ctx)
    ctx.tmux.run("new-session", "-d", "-s", "keepalive")
    enter_session(ctx)
    ctx.tmux.run("kill-session", "-t", SESSION)
    expect_gateway_back(ctx, "kill-session")


@scenario
def server_exit(ctx: Context) -> None:
    """`tmux kill-server` closes tmux tabs without crashing Ghostty."""
    two_window_layout(ctx)
    enter_session(ctx)
    ctx.tmux.kill_server()
    expect_gateway_back(ctx, "kill-server")


@scenario
def switch_client(ctx: Context) -> None:
    """`switch-client` replaces the tabs with the other session's; the gateway stays behind."""
    two_window_layout(ctx)
    ctx.tmux.run("new-session", "-d", "-s", "other", "-n", "gamma", "-x", "110", "-y", "30")
    ctx.tmux.run("new-window", "-d", "-t", "other", "-n", "delta")
    enter_session(ctx)
    client = ctx.tmux.control_clients()[0]
    ctx.tmux.run("switch-client", "-c", client, "-t", "other")

    wait_until(
        lambda: sorted(t.name for t in ctx.tmux_tabs()) == ["delta", "gamma"],
        timeout=ctx.timeout,
        desc="the tabs to be session 'other''s windows",
        describe_state=ctx.describe,
    )
    wait_until(
        lambda: ctx.gateway_window_name() == "tmux: other",
        timeout=ctx.timeout,
        desc="the gateway title to name the new session",
        describe_state=lambda: f"title {ctx.gateway_window_name()!r}",
    )
    # A session change is not the session ending: the user is taken to
    # the new windows, not back to the gateway.
    time.sleep(1)
    check(
        ctx.front_window() != ctx.gateway_window_name(),
        f"the gateway came to the front on switch-client{ctx.describe()}",
    )
    check(ctx.tmux.client_session(client) == "other", "the control client is not on 'other'")


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
        method = "growing the window via Accessibility"
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






# -- gateway -------------------------------------------------------------------


@scenario
def gateway_input_ignored(ctx: Context) -> None:
    """Keys and pastes into the gateway never reach tmux; the session keeps working."""
    ctx.attach()
    # Each would be a tmux command if it reached tmux's stdin: typed keys
    # would detach, the paste would kill the server.
    for key in "detach":
        ctx.app.send_key(ctx.gateway, key)
    ctx.app.send_key(ctx.gateway, "enter")
    ctx.app.input_text(ctx.gateway, "kill-server\n")
    ctx.app.input_text(ctx.gateway, "new-window -n pasted\r")

    # Nothing to wait for but the absence of an effect.
    time.sleep(2)
    check(ctx.tmux.alive(), "the tmux server died: the paste reached tmux")
    check(ctx.tmux.control_clients(), "the control client went away: the keys reached tmux")
    check(all(w.name != "pasted" for w in ctx.windows()), "a pasted command created a tmux window")

    ctx.tmux.run("new-window", "-t", SESSION, "-n", "after")
    ctx.wait_synced("the session to keep working after input to the gateway")
    ctx.tab_for_window("after")


@scenario
def gateway_shows_session(ctx: Context) -> None:
    """The gateway is titled and labelled with the session; Show Windows brings it forward."""
    two_window_layout(ctx)
    wait_until(
        lambda: ctx.gateway_window_name() == f"tmux: {SESSION}",
        timeout=ctx.timeout,
        desc="the gateway title to name the session",
        describe_state=lambda: f"title {ctx.gateway_window_name()!r}",
    )

    name = ctx.ax_window(ctx.gateway_window_name())
    wait_until(
        lambda: f"Attached to tmux session “{SESSION}”" in ax.window_texts(ctx.app.pid, name),
        timeout=ctx.timeout,
        desc="the gateway overlay to name the session",
        describe_state=lambda: repr(ax.window_texts(ctx.app.pid, name)),
    )

    ctx.app.focus(ctx.gateway)
    wait_until(lambda: ctx.front_window() == name, timeout=ctx.timeout, desc="the gateway to be in front")
    ax.press_button(ctx.app.pid, name, "Show Windows")
    wait_until(
        lambda: ctx.front_window() == "alpha",
        timeout=ctx.timeout,
        desc="Show Windows to bring tmux's current window forward",
        describe_state=ctx.describe,
    )


@scenario
def gateway_detach_action(ctx: Context) -> None:
    """The `tmux_detach` action on the gateway detaches, leaving the session running."""
    two_window_layout(ctx)
    check(ctx.app.perform(ctx.gateway, "tmux_detach"), "tmux_detach was not performed on the gateway")
    wait_until(
        lambda: not ctx.tmux.control_clients(),
        timeout=ctx.timeout,
        desc="the control client to detach",
        describe_state=lambda: f"clients: {ctx.tmux.clients()}",
    )
    expect_gateway_back(ctx, "tmux_detach")
    check([w.name for w in ctx.windows()] == ["alpha", "beta"], "the session did not survive the detach")


@scenario
def gateway_detach_button(ctx: Context) -> None:
    """The overlay's Detach button detaches."""
    two_window_layout(ctx)
    name = ctx.ax_window(f"tmux: {SESSION}")
    ax.press_button(ctx.app.pid, name, "Detach")
    wait_until(
        lambda: not ctx.tmux.control_clients(),
        timeout=ctx.timeout,
        desc="the control client to detach",
        describe_state=lambda: f"clients: {ctx.tmux.clients()}",
    )
    expect_gateway_back(ctx, "the Detach button")


# -- focus ---------------------------------------------------------------------


@scenario
def attach_focuses_active_panes(ctx: Context) -> None:
    """On attach each tab focuses tmux's active pane, and the selected tab doesn't flip."""
    ctx.open_gateway()
    ctx.create_session({"alpha": 3, "beta": 3})
    alpha, beta = ctx.windows()
    ctx.tmux.run("select-pane", "-t", alpha.panes[1].id)
    ctx.tmux.run("select-pane", "-t", beta.panes[2].id)
    ctx.attach_session()

    # Watch the selected tab for a while: it must settle on tmux's
    # current window and stay there.
    seen = []
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        selected = [t.name for t in ctx.tmux_tabs() if t.selected]
        if not seen or seen[-1] != selected:
            seen.append(selected)
        time.sleep(0.1)
    check(seen[-1] == ["alpha"], f"tab 'alpha' is not the selected one: {seen}{ctx.describe()}")
    check(len(seen) <= 2, f"the selected tab flipped while attaching: {seen}")

    def focused_pane(name: str) -> str | None:
        tab = ctx.tab_for_window(name)
        return ctx.pane_map(tab).get(tab.focused_terminal or "")

    wait_until(
        lambda: focused_pane("alpha") == alpha.panes[1].id,
        timeout=ctx.timeout,
        desc=f"tab 'alpha' to focus tmux's active pane {alpha.panes[1].id}",
        describe_state=ctx.describe,
    )
    # A background tab takes its focus when it is shown.
    ctx.app.select_tab(ctx.tab_for_window("beta"))
    wait_until(
        lambda: focused_pane("beta") == beta.panes[2].id,
        timeout=ctx.timeout,
        desc=f"tab 'beta' to focus tmux's active pane {beta.panes[2].id}",
        describe_state=ctx.describe,
    )
    check(ctx.active_pane("beta") == beta.panes[2].id, "showing tab 'beta' moved tmux's active pane")


@scenario
def tmux_select_pane_background(ctx: Context) -> None:
    """`select-pane` in a background window doesn't pull the GUI over; focus moves once it's shown."""
    two_window_layout(ctx)
    beta = ctx.tmux.window(SESSION, "beta")
    mapping = ctx.pane_map(ctx.tab_for_window("beta"))
    target = beta.panes[2].id
    ctx.tmux.run("select-pane", "-t", target)

    time.sleep(1.5)
    check(ctx.tab_for_window("alpha").selected, f"select-pane in a background window pulled the GUI over{ctx.describe()}")
    check(ctx.tmux.window(SESSION, "alpha").active, "tmux's current window moved")

    ctx.app.select_tab(ctx.tab_for_window("beta"))
    term = next(t for t, p in mapping.items() if p == target)
    wait_until(
        lambda: ctx.tab_for_window("beta").focused_terminal == term,
        timeout=ctx.timeout,
        desc=f"focus to be on {target} once tab 'beta' is shown",
        describe_state=ctx.describe,
    )
    check(ctx.active_pane("beta") == target, "showing the tab moved tmux's active pane")


@scenario
def gui_split_focuses_new_pane(ctx: Context) -> None:
    """A GUI split focuses the new pane, in the GUI and in tmux."""
    ctx.attach()
    tab = ctx.tab_for_window("main")
    old = ctx.tmux.window(SESSION, "main").panes[0].id
    ctx.app.focus(tab.terminals[0].id)
    ctx.app.perform(tab.terminals[0].id, "new_split:right")
    wait_until(
        lambda: len(ctx.tmux.window(SESSION, "main").panes) == 2,
        timeout=ctx.timeout,
        desc="a second pane in tmux window 'main'",
        describe_state=ctx.describe,
    )
    ctx.wait_synced()
    new = next(p.id for p in ctx.tmux.window(SESSION, "main").panes if p.id != old)
    wait_until(
        lambda: ctx.active_pane("main") == new,
        timeout=ctx.timeout,
        desc=f"tmux's active pane to be the new {new}",
        describe_state=ctx.describe,
    )
    mapping = ctx.pane_map(ctx.tab_for_window("main"))
    wait_until(
        lambda: mapping.get(ctx.tab_for_window("main").focused_terminal or "") == new,
        timeout=ctx.timeout,
        desc=f"GUI focus to be on the new pane {new}",
        describe_state=ctx.describe,
    )


# -- notices -------------------------------------------------------------------


def expect_text(ctx: Context, text: str, desc: str) -> None:
    """Wait for `text` in a static text of any window (notice bars, alerts)."""

    def found() -> bool:
        if any(text in t for t in ax.window_texts(ctx.app.pid)):
            return True
        ctx.app.activate()
        return False

    wait_until(
        found,
        timeout=ctx.timeout,
        desc=desc,
        describe_state=lambda: repr([t for t in ax.window_texts(ctx.app.pid) if "tmux" in t]),
    )


@scenario
def tmux_config_errors(ctx: Context) -> None:
    """A broken tmux.conf gives a single alert listing every error."""
    # Both mistakes have to be ones tmux runs into, not ones it fails to
    # parse: a parse error (an unknown command) abandons the rest of the
    # file, so tmux itself would only ever report the first.
    ctx.tmux.add_config("set -g e2e-no-such-option-one on\nset -g e2e-no-such-option-two on\n")
    two_window_layout(ctx)

    def sheets() -> list[list[str]]:
        found = ax.sheet_texts(ctx.app.pid)
        if not found:
            ctx.app.activate()
        return found

    shown = wait_until(sheets, timeout=ctx.timeout, desc="an alert for the tmux.conf errors")
    time.sleep(1.5)  # any second alert would be up by now
    shown = ax.sheet_texts(ctx.app.pid)
    check(len(shown) == 1, f"expected one alert, got {len(shown)}: {shown}")
    text = "\n".join(shown[0])
    for needle in ("e2e-no-such-option-one", "e2e-no-such-option-two"):
        check(needle in text, f"the alert does not mention {needle!r}: {shown[0]}")
    ax.dismiss_sheets(ctx.app.pid)


@scenario
def tmux_display_message(ctx: Context) -> None:
    """`display-message -c <client>` shows a notice bar."""
    ctx.attach()
    ctx.app.focus(ctx.tab_for_window("main").terminals[0].id)
    token = f"hello-{secrets.token_hex(3)}"
    ctx.tmux.run("display-message", "-c", ctx.tmux.control_clients()[0], token)
    expect_text(ctx, f"tmux: {token}", "the message on a notice bar")


@scenario
def gui_failed_split_notice(ctx: Context) -> None:
    """A split tmux refuses shows the error on a notice bar."""
    ctx.attach()
    term = ctx.tab_for_window("main").terminals[0].id
    ctx.app.focus(term)
    # A huge font leaves the window a few columns wide, and tmux refuses
    # to split a pane that has no room for another.
    ctx.app.perform(term, "set_font_size:200")
    wait_until(
        lambda: ctx.tmux.window(SESSION, "main").width < 12,
        timeout=ctx.timeout,
        desc="the tmux window to shrink with the font",
        describe_state=ctx.describe,
    )

    def refused() -> bool:
        if any("no space" in t for t in ax.window_texts(ctx.app.pid)):
            return True
        ctx.app.perform(ctx.tab_for_window("main").terminals[-1].id, "new_split:right")
        time.sleep(0.5)
        return False

    wait_until(
        refused,
        timeout=3 * ctx.timeout,
        interval=0.5,
        desc="tmux's refusal of a split on a notice bar",
        describe_state=lambda: repr([t for t in ax.window_texts(ctx.app.pid) if "tmux" in t]) + ctx.describe(),
    )


# -- menu ------------------------------------------------------------------------

TMUX_ITEMS = [
    "New Window",
    "Split Right",
    "Split Down",
    "Zoom Pane",
    "Swap Pane with Previous",
    "Swap Pane with Next",
    "Rotate Panes",
    "Break Pane into New Window",
    "Join Pane to Previous Window",
    "Join Pane to Next Window",
    "Kill Pane…",
    "Run Command…",
    "Detach",
]

# The items that are about the session rather than a pane, which the
# gateway can do too.
GATEWAY_ITEMS = ["Run Command…", "Detach"]


@scenario
def tmux_menu_enabled(ctx: Context) -> None:
    """File > tmux items are enabled on a tmux pane, only the session's on the gateway, none elsewhere."""
    ctx.attach()
    plain = ctx.app.new_window()
    plain_term = wait_until(
        lambda: next((t.terminals[0].id for w in ctx.app.snapshot().windows if w.id == plain for t in w.tabs), None),
        timeout=ctx.timeout,
        desc="an ordinary window",
    )

    def items_with_focus(term: str) -> dict[str, bool]:
        ctx.app.focus(term)
        time.sleep(0.5)
        ctx.app.activate()
        return ax.menu_items(ctx.app.pid, "File", "tmux")

    pane = items_with_focus(ctx.tab_for_window("main").terminals[0].id)
    check(set(pane) >= set(TMUX_ITEMS), f"the tmux menu is missing items: {pane}")
    check(all(pane[i] for i in TMUX_ITEMS), f"on a tmux pane every item should be enabled: {pane}")

    gateway = items_with_focus(ctx.gateway)
    check(all(gateway[i] for i in GATEWAY_ITEMS), f"{GATEWAY_ITEMS} should be enabled on the gateway: {gateway}")
    check(
        not any(gateway[i] for i in TMUX_ITEMS if i not in GATEWAY_ITEMS),
        f"only {GATEWAY_ITEMS} belong to the gateway: {gateway}",
    )

    other = items_with_focus(plain_term)
    check(not any(other[i] for i in TMUX_ITEMS), f"nothing should be enabled outside tmux: {other}")


# -- persistence -----------------------------------------------------------------


@scenario
def no_restore_after_relaunch(ctx: Context) -> None:
    """With window-save-state=always, tmux tabs don't come back; the gateway returns as a shell."""
    ctx.app.relaunch("window-save-state = always\n")
    try:
        ctx.app.close_all_windows(timeout=ctx.timeout)
        two_window_layout(ctx)
        ctx.app.quit()
        ctx.app.launch()

        # Restoration happens during launch; give it a moment to finish.
        time.sleep(2)
        snap = ctx.app.snapshot()
        names = [t.name for t in snap.tabs]
        check(not {"alpha", "beta"} & set(names), f"tmux tabs came back after relaunch: {snap.describe()}")
        check(snap.terminals, "the gateway's window did not come back")
        term = snap.terminals[0].id
        check(not ctx.tmux.control_clients(), "something re-attached to tmux after relaunch")
        ctx.app.type_line(term, "echo restored-$((40+2))")
        wait_until(
            lambda: "restored-42" in ctx.app.read_screen(term),
            timeout=ctx.timeout,
            desc="the restored window to run a normal shell",
        )
        check(not ctx.tmux.control_clients(), "the restored window re-attached to tmux")
    finally:
        ctx.gateway = ""
        ctx.app.relaunch()


@scenario
def undo_after_tmux_close(ctx: Context) -> None:
    """Undo after a tmux tab or pane closes does nothing."""
    two_window_layout(ctx)
    # Opening the gateway's window is itself undoable until `undo-timeout`
    # (5s) passes, and undoing that closes the gateway: a real undo, but
    # not what this is about. Let it expire first.
    time.sleep(5.5)
    ctx.tmux.run("kill-pane", "-t", ctx.tmux.window(SESSION, "beta").panes[1].id)
    ctx.wait_synced()
    ctx.tmux.run("kill-window", "-t", f"{SESSION}:beta")
    ctx.wait_synced()
    ctx.app.close(ctx.tab_for_window("alpha").terminals[0].id)
    wait_until(lambda: not ctx.tmux_tabs(), timeout=ctx.timeout, desc="the last tmux tab to close")

    before = ctx.app.snapshot().describe()
    for _ in range(3):
        ctx.app.perform(ctx.gateway, "undo")
    time.sleep(1.5)
    after = ctx.app.snapshot().describe()
    check(after == before, f"undo changed the GUI:\n    before: {before}\n    after:  {after}")
    try:
        ctx.app.activate()
        edit = ax.menu_items(ctx.app.pid, "Edit")
        undo = next((k for k in edit if k.startswith("Undo")), None)
        check(undo is None or not edit[undo], f"Undo is still offered: {edit}")
    except ax.AxUnavailable as exc:
        log(f"not checking the Undo menu item: {exc}")


# -- content -------------------------------------------------------------------


@scenario
def pane_throughput(ctx: Context) -> None:
    """A flood of output doesn't get the client dropped, and the GUI stays responsive."""
    ctx.attach()
    term = ctx.tab_for_window("main").terminals[0].id
    # A debug build checks the integrity of every terminal page it touches
    # and applies output about a thousand times slower than a release one
    # (seq 1 200000: about 155s against 0.2s in the core alone), slow enough
    # for tmux to drop it as too far behind. Its flood is cut to match.
    lines = 20000 if ctx.app.bundle_id.endswith(".debug") else 200000
    log(f"flooding with {lines} lines")
    ctx.tmux.run("send-keys", "-t", f"{SESSION}:main", f"seq 1 {lines}; echo flood-$((6*7))", "Enter")

    slowest = 0.0
    deadline = time.monotonic() + 120
    while "flood-42" not in ctx.tmux.capture(f"{SESSION}:main"):
        check(time.monotonic() < deadline, "the flood did not finish in tmux within 120s")
        start = time.monotonic()
        ctx.app.snapshot()
        slowest = max(slowest, time.monotonic() - start)
        check(ctx.tmux.control_clients(), "tmux dropped the control client during the flood")
        time.sleep(0.2)
    log(f"slowest AppleScript round trip during the flood: {slowest:.2f}s")
    check(slowest < 5, f"the GUI took {slowest:.1f}s to answer during the flood")

    wait_until(
        lambda: "flood-42" in ctx.app.read_screen(term),
        timeout=60,
        desc="the end of the flood on the GUI screen",
    )
    screen = ctx.app.read_screen(term)
    check(f"\n{lines}\n" in screen, "the last line of the flood is missing from the GUI")
    check(ctx.tmux.control_clients(), "tmux dropped the control client after the flood")


def _lines(text: str) -> list[str]:
    return [line.rstrip() for line in text.splitlines()]


@scenario
def pane_wide_chars(ctx: Context) -> None:
    """Wide characters take the same columns in the GUI as in tmux."""
    ctx.attach()
    term = ctx.tab_for_window("main").terminals[0].id
    # "W|" then four wide characters (8 columns), then ABCD, and a "*"
    # written at column 11 by absolute position: over the A if every wide
    # character is two columns wide, over another letter if not.
    ctx.tmux.run(
        "send-keys", "-t", f"{SESSION}:main",
        "printf 'W|\\346\\227\\245\\346\\234\\254\\350\\252\\236\\360\\237\\216\\211ABCD\\033[11G*\\n'",
        "Enter",
    )

    def tmux_line() -> str | None:
        return next((line for line in _lines(ctx.tmux.capture(f"{SESSION}:main")) if line.startswith("W|")), None)

    want = wait_until(tmux_line, timeout=ctx.timeout, desc="the wide characters in tmux")
    check(want == "W|日本語🎉*BCD", f"tmux did not lay the line out as expected: {want!r}")
    wait_until(
        lambda: want in _lines(ctx.app.read_screen(term)),
        timeout=ctx.timeout,
        desc=f"the GUI to show {want!r} exactly as tmux does",
        describe_state=lambda: repr([line for line in _lines(ctx.app.read_screen(term)) if line.startswith("W|")]),
    )


def _printf_octal(text: str) -> str:
    """`text` as a printf format of octal escapes, so the shell never sees
    the characters themselves."""
    return "".join(f"\\{b:03o}" for b in text.encode())


# Widths tmux 3.6 gives these, which the GUI must match. Not here, because
# it can't: an emoji with a skin tone modifier, which tmux doesn't join and
# makes four columns wide.
GRAPHEME_CASES = {
    "cjk-emoji-combining": "a\u65e5\u672c\u8a9eb\U0001f389ce\u0301\u0301d",
    "zwj-family": "\U0001f468\u200d\U0001f469\u200d\U0001f467",
    "vs16-heart": "\u2764\ufe0f",
    "vs16-warning": "\u26a0\ufe0f",
    "flag": "\U0001f1f8\U0001f1ea",
    "vs15-smiley": "\u263a\ufe0e",
}


@scenario
def pane_grapheme_widths(ctx: Context) -> None:
    """Graphemes take tmux's columns in the GUI, whatever the config or the program says about mode 2027."""
    # The config would have the GUI measure these differently. A pane's
    # grid is tmux's, so it must not.
    ctx.app.relaunch("grapheme-width-method = legacy\n")
    try:
        ctx.app.close_all_windows(timeout=ctx.timeout)
        ctx.attach()
        term = ctx.tab_for_window("main").terminals[0].id
        pane = f"{SESSION}:main"
        # As does a program turning grapheme clustering off, which tmux
        # ignores.
        ctx.tmux.run("send-keys", "-t", pane, "printf '\\033[?2027l'", "Enter")

        for i, (name, text) in enumerate(GRAPHEME_CASES.items()):
            # A "*" at a fixed column after the text lands on a different
            # letter if the GUI and tmux disagree about how wide it is.
            prefix = f"G{i}|"
            ctx.tmux.run(
                "send-keys", "-t", pane,
                f"printf '{prefix}{_printf_octal(text)}ABCDEFGHIJKLMNOP\\033[20G*\\n'",
                "Enter",
            )

            def tmux_line() -> str | None:
                return next((line for line in _lines(ctx.tmux.capture(pane)) if line.startswith(prefix)), None)

            want = wait_until(tmux_line, timeout=ctx.timeout, desc=f"{name} in tmux")
            check("*" in want, f"{name}: tmux did not lay the line out as expected: {want!r}")
            wait_until(
                lambda: want in _lines(ctx.app.read_screen(term)),
                timeout=ctx.timeout,
                desc=f"{name}: the GUI to show {want!r} exactly as tmux does",
                describe_state=lambda: repr(
                    [line for line in _lines(ctx.app.read_screen(term)) if line.startswith(prefix)]
                ),
            )
    finally:
        ctx.gateway = ""
        ctx.app.relaunch()


def _osc52(ctx: Context, text: str, then: str = "") -> None:
    encoded = base64.b64encode(text.encode()).decode()
    ctx.tmux.run("send-keys", "-t", f"{SESSION}:main", f"printf '\\033]52;c;{encoded}\\a'{then}", "Enter")


@scenario
def pane_osc52_clipboard(ctx: Context) -> None:
    """OSC 52 from a program in a pane sets the clipboard, as Ghostty's `clipboard-write` allows."""
    # tmux passes a pane's output to a control client as the program wrote
    # it, OSC 52 included, so the app sees the request itself. Whatever
    # `set-clipboard` says: that option is about the terminals tmux draws
    # on, and a control client is not one.
    saved = pbpaste()
    try:
        ctx.attach()
        for setting in ("on", "external", "off"):
            ctx.tmux.run("set", "-g", "set-clipboard", setting)
            text = f"osc52-{setting}-{secrets.token_hex(4)}"
            _osc52(ctx, text)
            wait_until(
                lambda: pbpaste() == text,
                timeout=ctx.timeout,
                desc=f"{text!r} on the clipboard (set-clipboard {setting})",
                describe_state=lambda: f"clipboard: {pbpaste()!r}",
            )

        # Which is Ghostty's to refuse.
        ctx.app.relaunch("clipboard-write = deny\n")
        ctx.gateway = ""
        ctx.app.close_all_windows(timeout=ctx.timeout)
        ctx.tmux.kill_server()
        ctx.attach()
        pbcopy("osc52-before")
        # The GUI showing what the program printed next means it has
        # been through the request.
        _osc52(ctx, "osc52-denied", "; echo osc52-$((6*7))")
        term = ctx.tab_for_window("main").terminals[0].id
        wait_until(
            lambda: "osc52-42" in ctx.app.read_screen(term),
            timeout=ctx.timeout,
            desc="the pane's output after the request in the GUI",
        )
        check(pbpaste() == "osc52-before", f"clipboard-write = deny let a pane write {pbpaste()!r}")
    finally:
        pbcopy(saved)
        if "clipboard-write = deny" in ctx.app.config.read_text():
            ctx.gateway = ""
            ctx.app.relaunch()


@scenario
def pane_passthrough_unwrapped(ctx: Context) -> None:
    """A sequence wrapped in tmux's passthrough escape takes effect, and nothing else in the wrapper does."""
    # Claude Code wraps its notifications like this whenever $TMUX is set.
    # A notification cannot be seen from here, but a clipboard write goes
    # through the same unwrapping. `allow-passthrough` stays at its
    # default, off: a control client gets the pane's raw output anyway.
    saved = pbpaste()
    try:
        ctx.attach()
        text = f"wrapped-{secrets.token_hex(4)}"
        encoded = base64.b64encode(text.encode()).decode()
        # The wrapper also holds text, which tmux never draws. Spelled
        # through a variable so the command line itself does not show it.
        rest = f"-in-wrapper\\033\\033]52;c;{encoded}\\a\\033\\\\"
        ctx.tmux.run(
            "send-keys",
            "-t",
            f"{SESSION}:main",
            f"j=junk; printf '\\033Ptmux;'\"$j\"'{rest}'; echo pt-$((6*7))",
            "Enter",
        )
        wait_until(
            lambda: pbpaste() == text,
            timeout=ctx.timeout,
            desc=f"{text!r} on the clipboard from inside the wrapper",
            describe_state=lambda: f"clipboard: {pbpaste()!r}",
        )
        term = ctx.tab_for_window("main").terminals[0].id
        wait_until(
            lambda: "pt-42" in ctx.app.read_screen(term),
            timeout=ctx.timeout,
            desc="the pane's output after the wrapper in the GUI",
        )
        screen = ctx.app.read_screen(term)
        check("junk-in-wrapper" not in screen, "text inside the wrapper was drawn")
    finally:
        pbcopy(saved)


def _numbered_file(ctx: Context, lines: int) -> str:
    path = ctx.tmux.conf.parent / "numbered.txt"
    path.write_text("".join(f"line-{i:04d}\n" for i in range(1, lines + 1)))
    return str(path)


def expect_same_screen(ctx: Context, term: str, pane: str, desc: str) -> None:
    """The GUI terminal shows the `line-NNNN` lines tmux shows for the pane."""

    def marks(text: str) -> list[str]:
        return re.findall(r"line-\d{4}", text)

    want = marks(ctx.tmux.capture(pane))
    check(want, f"tmux shows no numbered lines in {pane}: {ctx.tmux.capture(pane)!r}")
    wait_until(
        lambda: marks(ctx.app.read_screen(term)) == want,
        timeout=ctx.timeout,
        desc=desc,
        describe_state=lambda: f"tmux {want[:3]}..{want[-1:]}, gui {marks(ctx.app.read_screen(term))[:3]}..",
    )


@scenario
def pane_alt_screen(ctx: Context) -> None:
    """less (alternate screen) in a pane shows what tmux shows, and leaving it restores the shell."""
    ctx.attach()
    term = ctx.tab_for_window("main").terminals[0].id
    path = _numbered_file(ctx, 500)
    pane = f"{SESSION}:main"
    ctx.tmux.run("send-keys", "-t", pane, "clear; echo before-less", "Enter")
    ctx.tmux.run("send-keys", "-t", pane, f"less {path}", "Enter")
    wait_until(lambda: "line-0001" in ctx.tmux.capture(pane), timeout=ctx.timeout, desc="less in tmux")
    expect_same_screen(ctx, term, pane, "the GUI to show less's screen")
    ctx.tmux.run("send-keys", "-t", pane, "q")
    wait_until(
        lambda: "line-0001" not in ctx.app.read_screen(term) and "before-less" in ctx.app.read_screen(term),
        timeout=ctx.timeout,
        desc="the shell's screen back in the GUI after less",
    )


@scenario
def attach_while_vim_open(ctx: Context) -> None:
    """Attaching while vim is open shows vim's screen."""
    ctx.open_gateway()
    ctx.create_session()
    path = _numbered_file(ctx, 500)
    pane = f"{SESSION}:main"
    ctx.tmux.run("send-keys", "-t", pane, f"vim -u NONE -N {path}", "Enter")
    wait_until(lambda: "line-0001" in ctx.tmux.capture(pane), timeout=ctx.timeout, desc="vim in tmux")
    ctx.attach_session()
    term = ctx.tab_for_window("main").terminals[0].id
    expect_same_screen(ctx, term, pane, "the GUI to show vim's screen")
    ctx.tmux.run("send-keys", "-t", pane, "Escape", ":qa!", "Enter")


@scenario
def attach_with_history(ctx: Context) -> None:
    """Attaching to panes with long history makes the history scrollable in the GUI."""
    ctx.open_gateway()
    ctx.create_session({"alpha": 1, "beta": 2})
    panes = [p.id for w in ctx.windows() for p in w.panes]
    for i, pane in enumerate(panes):
        ctx.tmux.run("send-keys", "-t", pane, f"seq -f 'p{i}-%04g' 1 1500", "Enter")
    for i, pane in enumerate(panes):
        wait_until(lambda: f"p{i}-1500" in ctx.tmux.capture(pane), timeout=ctx.timeout, desc=f"history in {pane}")
    ctx.attach_session()

    for name in ("alpha", "beta"):
        tab = ctx.tab_for_window(name)
        for term, pane in ctx.pane_map(tab).items():
            want = [line for line in _lines(ctx.tmux.capture_all(pane)) if re.fullmatch(r"p\d-\d{4}", line)]
            check(len(want) >= 1000, f"tmux kept only {len(want)} history lines in {pane}")

            def gui() -> list[str]:
                return [line for line in _lines(ctx.app.read_scrollback(term)) if re.fullmatch(r"p\d-\d{4}", line)]

            # The scrollback holds everything above the screen; the screen
            # holds the rest, so together they must be tmux's whole history.
            wait_until(
                lambda: want[: len(gui())] == gui() and len(gui()) >= len(want) - 40,
                timeout=ctx.timeout,
                desc=f"the GUI's history of {pane} to match tmux's",
                describe_state=lambda: f"tmux {len(want)} lines {want[:1]}..{want[-1:]}, gui {len(gui())} lines {gui()[:1]}..{gui()[-1:]}",
            )


def _scroll_positions(ctx: Context, window_name: str) -> list[float]:
    """The scroll bar position (1.0 is the bottom) of each terminal in a tab.

    Read from the native scroll bars over Accessibility. Not from the app
    log: the scrollbar actions are logged at debug level, which only a
    debug build emits.
    """
    return ax.scroll_positions(ctx.app.pid, ctx.ax_window(window_name))


@scenario
def pane_mouse_scroll(ctx: Context) -> None:
    """The mouse wheel scrolls a pane's history in the GUI."""
    ctx.attach()
    term = ctx.tab_for_window("main").terminals[0].id
    ctx.tmux.run("send-keys", "-t", f"{SESSION}:main", "seq 1 500", "Enter")
    wait_until(lambda: "\n500" in ctx.app.read_screen(term), timeout=ctx.timeout, desc="history in the GUI")
    wait_until(
        lambda: _scroll_positions(ctx, "main") == [1.0],
        timeout=ctx.timeout,
        desc="the pane's scroll bar to be at the bottom",
        describe_state=lambda: f"scroll bars {_scroll_positions(ctx, 'main')}",
    )
    ctx.app.focus(term)
    ctx.app.scroll(term, 10)
    wait_until(
        lambda: (bars := _scroll_positions(ctx, "main")) and bars[0] < 1.0,
        timeout=ctx.timeout,
        desc="the viewport to scroll up into history",
        describe_state=lambda: f"scroll bars {_scroll_positions(ctx, 'main')}",
    )
    check(ctx.tmux.control_clients(), "scrolling dropped the control client")


@scenario
def pane_mouse_reporting(ctx: Context) -> None:
    """A program in a pane that asks for the mouse gets clicks and the wheel, and history isn't scrolled."""
    ctx.attach({"main": 2})
    pane = ctx.tmux.window(SESSION, "main").panes[1].id
    term = ctx.terminal_for_pane(pane)
    # SGR reporting of presses, releases and the wheel. `cat -v` stays in
    # the tty's canonical mode, whose echo shows each report as it arrives
    # (ESC as `^[`).
    ctx.tmux.run("send-keys", "-t", pane, "printf '\\033[?1000h\\033[?1006hmouse-%s\\n' ready; cat -v", "Enter")
    wait_until(
        lambda: "mouse-ready" in ctx.app.read_screen(term),
        timeout=ctx.timeout,
        desc="the program's request for the mouse in the GUI",
    )
    try:
        before = _scroll_positions(ctx, "main")
    except ax.AxUnavailable as exc:
        log(f"not checking that history stays put: {exc}")
        before = None

    # A click near the pane's top left corner, which the program must get
    # in the pane's own cells (tmux's are 1-based), not the window's.
    ctx.app.focus(term)
    ctx.app.click(term, 20, 20)
    click = wait_until(
        lambda: re.search(r"\^\[\[<0;(\d+);(\d+)M\^\[\[<0;\1;\2m", ctx.tmux.capture(pane)),
        timeout=ctx.timeout,
        desc="the program to read a press and a release at the same cell",
        describe_state=lambda: repr(ctx.tmux.capture(pane)),
    )
    col, row = int(click[1]), int(click[2])
    check(1 <= col <= 5 and 1 <= row <= 3, f"the click arrived at {col};{row}, not near the pane's corner")

    ctx.app.scroll(term, 3)
    wait_until(
        lambda: f"^[[<64;{col};{row}M" in ctx.tmux.capture(pane),
        timeout=ctx.timeout,
        desc="the program to read the wheel",
        describe_state=lambda: repr(ctx.tmux.capture(pane)),
    )
    if before is not None:
        after = _scroll_positions(ctx, "main")
        check(after == before, f"the wheel scrolled the pane's history: scroll bars {before} -> {after}")
    check(ctx.tmux.control_clients(), "mouse input dropped the control client")
    check(ctx.tab_for_window("main").focused_terminal == term, "the click moved focus off the pane")


@scenario
def read_only_client(ctx: Context) -> None:
    """`switch-client -r` keeps the session on screen; typing and splits are refused with a notice."""
    ctx.attach()
    term = ctx.tab_for_window("main").terminals[0].id
    pane = ctx.tmux.window(SESSION, "main").panes[0].id
    client = ctx.tmux.control_clients()[0]
    ctx.app.focus(term)

    ctx.tmux.run("switch-client", "-c", client, "-r")
    expect_text(ctx, "read-only", "a notice that the client is read-only")
    check(ctx.tmux.control_clients(), "going read-only dropped the control client")
    # tmux announces the change as a session change, and the session's
    # panes are dropped and come straight back. AppleScript cannot see
    # the terminals while that happens: wait until it can again, steadily.
    def settled() -> bool:
        try:
            for _ in range(3):
                ctx.tab_for_window("main")
                time.sleep(0.2)
            return True
        except (CheckFailed, AppleScriptError):
            return False

    wait_until(settled, timeout=ctx.timeout, desc="the session's terminals to settle")
    ctx.wait_synced()
    term = ctx.tab_for_window("main").terminals[0].id
    ctx.app.focus(term)

    # tmux would run whatever we sent; nothing should be.
    token = secrets.token_hex(3)
    ctx.app.type_line(term, f"echo refused-{token}")
    ctx.app.perform(term, "new_split:right")
    expect_text(ctx, "client is read-only", "the refusal on a notice bar")
    time.sleep(1)
    check(f"refused-{token}" not in ctx.tmux.capture(pane), "typing reached a read-only client's pane")
    check(len(ctx.tmux.window(SESSION, "main").panes) == 1, "a read-only client split a pane")

    # Output still arrives.
    ctx.tmux.run("send-keys", "-t", pane, f"echo shown-{token}", "Enter")
    wait_until(
        lambda: f"shown-{token}" in ctx.app.read_screen(ctx.tab_for_window("main").terminals[0].id),
        timeout=ctx.timeout,
        desc="output from elsewhere on screen while read-only",
    )

    # And back.
    ctx.tmux.run("switch-client", "-c", client, "-r")
    expect_text(ctx, "no longer read-only", "a notice that the client may write again")
    wait_until(settled, timeout=ctx.timeout, desc="the session's terminals to settle")
    ctx.wait_synced()
    term = ctx.tab_for_window("main").terminals[0].id
    ctx.app.type_line(term, f"echo typed-{token}")
    wait_until(
        lambda: f"typed-{token}" in ctx.tmux.capture(pane),
        timeout=ctx.timeout,
        desc="typing to reach the pane again",
        describe_state=lambda: ctx.tmux.capture(pane).strip()[-300:],
    )
    ctx.wait_synced()


@scenario
def switch_client_same_session(ctx: Context) -> None:
    """`switch-client` to the session already shown (as `-r` does) rebuilds the tabs without killing a pane."""
    ctx.attach()
    client = ctx.tmux.control_clients()[0]
    before = [p.id for p in ctx.tmux.window(SESSION, "main").panes]
    for _ in range(3):
        ctx.tmux.run("switch-client", "-c", client, "-t", SESSION)
        time.sleep(1.5)
        check(ctx.tmux.control_clients(), "the control client went away")
        check(
            [p.id for p in ctx.tmux.window(SESSION, "main").panes] == before,
            f"the panes changed: {before} -> {ctx.describe()}",
        )
    ctx.wait_synced()


# -- alerts, titles and working directories ------------------------------------

# What a tab shows in front of the window name for tmux's window flags.
ALERT_MARKS = {"bell": "🔔", "activity": "•", "silence": "💤"}


def tab_marks(ctx: Context, window: str) -> str:
    """The marks in front of the name of the tab for tmux window `window`."""
    for tab in ctx.tmux_tabs():
        if tab.name == window:
            return ""
        if tab.name.endswith(" " + window):
            return tab.name[: -len(window) - 1]
    raise CheckFailed(f"no tab named {window!r}{ctx.describe()}")


def expect_marks(ctx: Context, window: str, want: set[str], desc: str) -> None:
    """Wait until the tab for `window` carries exactly the marks in `want`."""

    def marked() -> bool:
        try:
            marks = tab_marks(ctx, window)
        except (CheckFailed, AppleScriptError):
            return False
        return all(ALERT_MARKS[m] in marks for m in want) and bool(marks) == bool(want)

    wait_until(marked, timeout=ctx.timeout, desc=desc, describe_state=ctx.describe)


def select_tab_named(ctx: Context, window: str) -> None:
    """Select the tab for `window`, whatever marks it carries."""
    tab = next(t for t in ctx.tmux_tabs() if t.name == window or t.name.endswith(" " + window))
    ctx.app.select_tab(tab)


def window_flag(ctx: Context, window: str, flag: str) -> str:
    return ctx.tmux.run("display-message", "-p", "-t", f"{SESSION}:{window}", f"#{{{flag}}}").strip()


@scenario
def tmux_bell_marks_tab(ctx: Context) -> None:
    """A bell in a background tmux window marks its tab until the tab is selected."""
    two_window_layout(ctx)
    pane = ctx.tmux.window(SESSION, "beta").panes[0].id
    ctx.tmux.run("send-keys", "-t", pane, "printf '\\007'", "Enter")
    wait_until(
        lambda: window_flag(ctx, "beta", "window_bell_flag") == "1",
        timeout=ctx.timeout,
        desc="tmux to flag the bell in window 'beta'",
    )
    expect_marks(ctx, "beta", {"bell"}, "the bell mark on tab 'beta'")
    check(tab_marks(ctx, "alpha") == "", f"tab 'alpha' is marked too{ctx.describe()}")

    # Selecting the tab moves tmux to the window, which is what clears it.
    select_tab_named(ctx, "beta")
    expect_marks(ctx, "beta", set(), "the bell mark to clear once tab 'beta' is selected")
    check(window_flag(ctx, "beta", "window_bell_flag") == "0", "tmux kept the bell flag")
    ctx.wait_synced()


@scenario
def tmux_activity_marks_tab(ctx: Context) -> None:
    """With monitor-activity on, output in a background window marks its tab."""
    ctx.tmux.add_config("set -g monitor-activity on\n")
    two_window_layout(ctx)
    pane = ctx.tmux.window(SESSION, "beta").panes[0].id
    ctx.tmux.run("send-keys", "-t", pane, "echo busy", "Enter")
    expect_marks(ctx, "beta", {"activity"}, "the activity mark on tab 'beta'")
    select_tab_named(ctx, "beta")
    expect_marks(ctx, "beta", set(), "the activity mark to clear once tab 'beta' is selected")
    ctx.wait_synced()


@scenario
def tmux_pane_title(ctx: Context) -> None:
    """A pane's tmux title (`select-pane -T`) becomes its terminal's title, live."""
    ctx.attach()
    pane = ctx.tmux.window(SESSION, "main").panes[0].id
    for title in (f"title-{secrets.token_hex(3)}", f"again-{secrets.token_hex(3)}"):
        ctx.tmux.run("select-pane", "-t", pane, "-T", title)
        wait_until(
            lambda: ctx.tab_for_window("main").terminals[0].name == title,
            timeout=ctx.timeout,
            desc=f"the terminal's title to become {title!r}",
            describe_state=lambda: repr(ctx.tab_for_window("main").terminals[0].name),
        )


@scenario
def tmux_pane_title_on_attach(ctx: Context) -> None:
    """The title a pane already had before attaching is its terminal's title."""
    ctx.open_gateway()
    ctx.create_session()
    title = f"before-{secrets.token_hex(3)}"
    ctx.tmux.run("select-pane", "-t", f"{SESSION}:main", "-T", title)
    ctx.attach_session()
    wait_until(
        lambda: ctx.tab_for_window("main").terminals[0].name == title,
        timeout=ctx.timeout,
        desc=f"the terminal's title to be {title!r}",
        describe_state=lambda: repr(ctx.tab_for_window("main").terminals[0].name),
    )


@scenario
def tmux_pane_working_directory(ctx: Context) -> None:
    """A pane's working directory, as tmux sees it, is its terminal's."""
    ctx.attach()
    pane = ctx.tmux.window(SESSION, "main").panes[0].id
    ctx.tmux.run("send-keys", "-t", pane, "cd /usr/bin", "Enter")
    wait_until(
        lambda: ctx.tab_for_window("main").terminals[0].cwd.rstrip("/").endswith("/usr/bin"),
        timeout=ctx.timeout,
        desc="the terminal's working directory to follow the pane's",
        describe_state=lambda: repr(ctx.tab_for_window("main").terminals[0].cwd),
    )


@scenario
def hidden_pane_catches_up(ctx: Context) -> None:
    """With tmux-hidden-output-off-after, a busy background pane is current again once shown."""
    ctx.app.relaunch("tmux-hidden-output-off-after = 1\n")
    ctx.attach({"alpha": 1, "beta": 1})
    pane = ctx.tmux.window(SESSION, "beta").panes[0].id
    ctx.tmux.run("send-keys", "-t", pane, "i=0; while :; do i=$((i+1)); echo tick-$i; sleep 0.1; done", "Enter")

    # Long enough for the hidden pane to be turned off and to miss output.
    time.sleep(4)
    select_tab_named(ctx, "beta")
    term = ctx.tab_for_window("beta").terminals[0].id

    def last_tick(text: str) -> int:
        ticks = re.findall(r"tick-(\d+)", text)
        return int(ticks[-1]) if ticks else -1

    def caught_up() -> bool:
        gui = last_tick(ctx.app.read_screen(term))
        return gui > 0 and last_tick(ctx.tmux.capture(pane)) - gui <= 10

    wait_until(
        caught_up,
        timeout=ctx.timeout,
        desc="the pane, shown again, to show what tmux has",
        describe_state=lambda: f"gui {last_tick(ctx.app.read_screen(term))} tmux {last_tick(ctx.tmux.capture(pane))}",
    )
    ctx.tmux.run("send-keys", "-t", pane, "C-c")
# -- rearranging panes and tabs ------------------------------------------------


def pane_order(ctx: Context, name: str) -> list[str]:
    return [p.id for p in ctx.tmux.window(SESSION, name).panes]


def gui_tab_order(ctx: Context) -> list[str]:
    return [t.name for t in ctx.tmux_tabs()]


@scenario
def gui_swap_and_rotate_panes(ctx: Context) -> None:
    """`tmux_swap_pane` and `tmux_rotate_window` rearrange the tmux window's panes."""
    two_window_layout(ctx)
    ctx.tmux.run("select-window", "-t", f"{SESSION}:beta")
    before = pane_order(ctx, "beta")
    term = ctx.terminal_for_pane(before[0])

    ctx.app.perform(term, "tmux_swap_pane:next")
    wait_until(
        lambda: pane_order(ctx, "beta") == [before[1], before[0], before[2]],
        timeout=ctx.timeout,
        desc="the first two panes of 'beta' to trade places",
        describe_state=ctx.describe,
    )
    # Focus goes with the pane that moved.
    check(ctx.active_pane("beta") == before[0], f"{before[0]} should still be active{ctx.describe()}")

    ctx.app.perform(term, "tmux_rotate_window:next")
    wait_until(
        lambda: pane_order(ctx, "beta") != [before[1], before[0], before[2]],
        timeout=ctx.timeout,
        desc="the panes of 'beta' to rotate",
        describe_state=ctx.describe,
    )
    ctx.wait_synced()


@scenario
def gui_break_and_join_pane(ctx: Context) -> None:
    """`tmux_break_pane` gives a pane a tab of its own; `tmux_join_pane` puts it back."""
    two_window_layout(ctx)
    ctx.tmux.run("select-window", "-t", f"{SESSION}:beta")
    pane = pane_order(ctx, "beta")[1]
    ctx.app.perform(ctx.terminal_for_pane(pane), "tmux_break_pane")
    wait_until(
        lambda: len(ctx.windows()) == 3 and len(ctx.tmux.window(SESSION, "beta").panes) == 2,
        timeout=ctx.timeout,
        desc=f"{pane} to be broken out into a third window",
        describe_state=ctx.describe,
    )
    ctx.wait_synced()

    # The new window is after 'beta', so 'beta' is the one before it.
    ctx.app.perform(ctx.terminal_for_pane(pane), "tmux_join_pane:previous")
    wait_until(
        lambda: len(ctx.windows()) == 2 and pane in pane_order(ctx, "beta"),
        timeout=ctx.timeout,
        desc=f"{pane} to be joined back into 'beta'",
        describe_state=ctx.describe,
    )
    ctx.wait_synced()


@scenario
def gui_move_tab_two_along(ctx: Context) -> None:
    """`move_tab:2` moves the tmux window two along, and the tabs follow tmux's order."""
    ctx.attach({"alpha": 1, "beta": 1, "gamma": 1})
    term = ctx.tab_for_window("alpha").terminals[0].id
    ctx.app.perform(term, "move_tab:2")
    want = ["beta", "gamma", "alpha"]
    wait_until(
        lambda: [w.name for w in ctx.windows()] == want,
        timeout=ctx.timeout,
        desc=f"tmux's windows in the order {want}",
        describe_state=ctx.describe,
    )
    wait_until(
        lambda: gui_tab_order(ctx) == want,
        timeout=ctx.timeout,
        desc=f"the tabs in the order {want}",
        describe_state=ctx.describe,
    )


@scenario
def tmux_swap_window_reorders_tabs(ctx: Context) -> None:
    """`tmux swap-window` from outside reorders the tabs (tmux 3.2+, within a few seconds)."""
    ctx.attach({"alpha": 1, "beta": 1, "gamma": 1})
    ctx.tmux.run("swap-window", "-d", "-s", f"{SESSION}:alpha", "-t", f"{SESSION}:gamma")
    want = ["gamma", "beta", "alpha"]
    wait_until(
        lambda: gui_tab_order(ctx) == want,
        timeout=ctx.timeout,
        desc=f"the tabs in the order {want}",
        describe_state=ctx.describe,
    )


@scenario
def gui_tmux_command(ctx: Context) -> None:
    """`tmux_command:<line>` runs the line in the session (the prompt is the same path)."""
    two_window_layout(ctx)
    term = ctx.tab_for_window("alpha").terminals[0].id
    ctx.app.perform(term, "tmux_command:rename-window -t alpha typed ; select-window -t beta")
    wait_until(
        lambda: {w.name for w in ctx.windows()} == {"typed", "beta"} and ctx.tmux.window(SESSION, "beta").active,
        timeout=ctx.timeout,
        desc="both commands of the line to have run",
        describe_state=ctx.describe,
    )
    ctx.wait_synced()

    # From the gateway too: it is the session's, not a pane's.
    ctx.app.perform(ctx.gateway, "tmux_command:rename-window -t beta from-gateway")
    wait_until(
        lambda: "from-gateway" in {w.name for w in ctx.windows()},
        timeout=ctx.timeout,
        desc="the gateway's command to have run",
        describe_state=ctx.describe,
    )


@scenario
def gui_status_bar(ctx: Context) -> None:
    """`tmux-status-bar = true` shows tmux's status line (screenshot; verify manually)."""
    ctx.app.relaunch("tmux-status-bar = true\n")
    try:
        ctx.app.close_all_windows(timeout=ctx.timeout)
        ctx.tmux.add_config("set -g status-right 'e2e-status-right'\n")
        ctx.attach()
        # tmux checks subscriptions about once a second.
        time.sleep(3)
        shots = screenshot(ctx.app.pid, ctx.out_dir, "gui_status_bar")
    finally:
        ctx.gateway = ""
        ctx.app.relaunch()
    raise Skip(f"the status bar is SwiftUI text AppleScript cannot read; inspect {', '.join(map(str, shots))}")


@scenario
def gui_drag_tabs_and_splits(ctx: Context) -> None:
    """Dragging tabs and splits is mirrored to tmux (needs a mouse; manual)."""
    raise Skip(
        "drag and drop is not scriptable here; verify manually: drag a tmux tab along the tab bar "
        "(tmux list-windows follows), drag a split onto another pane's edge (join-pane), and out of "
        "the window (break-pane, opening as a window where it was dropped)"
    )
