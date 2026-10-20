<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://github.com/user-attachments/assets/fe853809-ba8b-400b-83ab-a9a0da25be8a" alt="Logo" width="128">
  <br>Ghostty
</h1>
  <p align="center">
    Fast, native, feature-rich terminal emulator pushing modern features.
    <br />
    A native GUI or embeddable library via <code>libghostty</code>.
    <br />
    <a href="#about">About</a>
    ·
    <a href="https://ghostty.org/download">Download</a>
    ·
    <a href="https://ghostty.org/docs">Documentation</a>
    ·
    <a href="CONTRIBUTING.md">Contributing</a>
    ·
    <a href="HACKING.md">Developing</a>
  </p>
</p>

> [!NOTE]
> **This is a personal fork of [Ghostty](https://github.com/ghostty-org/ghostty)**
> that adds **native tmux control mode (`tmux -CC`) integration on macOS**,
> in the spirit of iTerm2's tmux integration. Everything else is upstream
> Ghostty, merged in automatically every week. See
> [About this fork](#about-this-fork) below; the rest of this README is
> upstream's.

## About this fork

### What it changes

Run `tmux -CC` (or `tmux -CC attach`, over ssh or locally) in any Ghostty
terminal and the session opens as native Ghostty windows:

- **tmux windows are native tabs, tmux panes are native splits.** Layouts
  follow tmux exactly, including zoom, and are rebuilt live as they change
  from any client.
- **Ghostty's verbs go to tmux.** New tab is `new-window`, new split is
  `split-window` (all four directions), closing a split or tab kills the
  tmux pane or window (always confirmed), zoom is `resize-pane -Z`, moving
  a tab is `swap-window`, renaming a tab is `rename-window`, and dragging a
  divider resizes the tmux pane. Each tmux window is sized from its own
  Ghostty window (tmux 3.4+, with a fallback for older servers).
- **Focus follows both ways.** Focusing a split selects the tmux pane, and
  `select-pane`/`select-window` from tmux or another client moves Ghostty.
- **Full history on attach**, both screens, cursor and terminal modes
  (modifyOtherKeys too, from tmux 3.5), so scrollback, search and
  selection are Ghostty's own. Typing, IME and pastes (bracketed exactly
  when the pane's program asked for it) are sent through tmux; queries are
  answered by tmux only.
- **The terminal that ran `tmux -CC`** shows which session it hosts and
  offers _Show Windows_ and _Detach_; it no longer swallows keys as tmux
  commands. Closing it says it detaches, and the session keeps running.
- **File › tmux menu** (New Window, Split Right/Down, Zoom Pane, Kill Pane,
  Detach) and a `tmux_detach` keybind action (unbound by default).
- **tmux talks back**: `display-message`, tmux.conf errors, refused
  commands and the reason a session ended are shown as notices or alerts.
- **Notifications, links and passthrough from panes**: OSC 9, OSC 777 and
  OSC 99 notifications become native notifications of the pane they came
  from (clicking one brings its tab and split forward), whether sent as is
  or wrapped in tmux's `DCS tmux;` passthrough, which is unwrapped
  whatever `allow-passthrough` says. Of what is wrapped only OSC, DCS and
  APC sequences (clipboard, kitty graphics) take effect, since tmux never
  sees them. OSC 8 hyperlinks are clickable, including ones in history
  read on attach. Inside tmux, `TERM_PROGRAM` is `tmux`, so tools cannot
  tell they are in Ghostty: Claude Code, for one, sends no notification
  on its `auto` channel there; set it to `ghostty` (OSC 777) with
  `claude config set --global preferredNotifChannel ghostty`.
- **Robust sessions**: detach, `kill-session`, `kill-server`, `switch-client`
  (including to the same session), dropped ssh connections, large histories,
  floods (optional `tmux-pause-after = <seconds>`) and read-only clients
  (`attach -r` / `switch-client -r`: the session stays visible, input is
  refused with a notice) are all handled. tmux windows are not restored on
  relaunch and closes done by tmux are not undoable.

Linux (GTK) gets the core tmux windows-as-tabs support, but the macOS app
is what this fork is built and tested for.

The implementation lives in `src/terminal/tmux/` (protocol, viewer, router),
`src/termio/` (the pty-less tmux pane backend) and
`macos/Sources/Features/Terminal/TmuxWindowManager.swift`. It is covered by
unit tests (`zig build test -Dtest-filter=tmux`), tests against a real tmux
server (`zig build test-tmux-live`) and GUI end-to-end tests that drive the
app (`test/tmux-e2e/`).

### Download

macOS builds (Apple silicon) are on the
[Releases page](https://github.com/eliasfloreteng/ghostty-tmux/releases) as
**Ghostty tmux.app**. It has its own name and bundle identifier
(`com.eliasfloreteng.ghostty-tmux`), so it installs and runs alongside the
official Ghostty with its own preferences and permissions, while reading
the same Ghostty config. Its updater is disabled, so it never "updates"
itself into the official release. Unless the build workflow has signing
secrets (see [`fork-build.yml`](.github/workflows/fork-build.yml)), a
release is ad-hoc signed and not notarized: after unzipping, run
`xattr -dr com.apple.quarantine "Ghostty tmux.app"` (or right-click ›
Open) once.

To build and install it from a checkout instead, run
[`dist/macos/install-fork.sh`](dist/macos/install-fork.sh). Signing it with
a certificate (`SIGN_IDENTITY="Apple Development" dist/macos/install-fork.sh`)
keeps macOS permissions across updates; an ad-hoc signed build is a new
app to macOS every time.

### Staying in sync with upstream

A [weekly workflow](.github/workflows/fork-sync-upstream.yml) merges
`ghostty-org/ghostty`'s `main` into this fork's `main`, keeping the fork's
changes. It stops without pushing when the merge conflicts, and skips the
update when the tests (including the live tmux tests) fail after the
merge, so `main` only ever moves to a merge that builds and passes. It can
also be run by hand from the Actions tab.

Every successful sync, and every push to `main`, is followed by the
[build workflow](.github/workflows/fork-build.yml), which builds
**Ghostty tmux.app** on a GitHub-hosted Mac and publishes it as a release
tagged `build-<commit>` (once per commit).

### Future work

Not done yet, roughly in order of usefulness:

- Notification passthrough: desktop notifications from programs inside
  tmux panes (for example Claude Code when it needs input or finishes),
  sent as OSC 9, OSC 777 or OSC 99, or wrapped in tmux's `DCS tmux;`
  passthrough (`allow-passthrough`), should become native Ghostty
  notifications for that pane, and clicking one should bring its tab and
  split forward. Still to find out: which of these tmux forwards to a
  control client as plain `%output` (and so may already work) and which it
  consumes or rewrites, and how tools detect the terminal when
  `TERM_PROGRAM` is `tmux`.
- Bell, activity and silence markers on tabs from tmux's window flags.
- Mirroring tab drag-and-drop (reorder, tear off) to tmux.
- Per-pane titles (`#{pane_title}`) on splits.
- A session picker / dashboard: list sessions, attach, choose which windows
  to show, hide windows (iTerm2's tmux dashboard).
- Options: open tmux windows as separate windows or tabs, hide the host
  terminal while attached, cap history read on attach, mirror tmux paste
  buffers to the clipboard, extra client flags (`active-pane`,
  `no-detach-on-destroy`).
- `refresh-client -B` subscriptions (pane titles, working directory,
  activity) and turning off output for panes not on screen.
- A "paused, catching up" indicator per pane when `tmux-pause-after`
  kicks in, and reading history lazily so big sessions attach faster.
- Swap, rotate, break and join panes from the GUI.
- Mirroring tmux's status line, and a "run tmux command" prompt.
- Restoring keyboard protocol modes (modifyOtherKeys, kitty keyboard) and
  passing through DCS/image passthrough sequences.
- A clear message for tmux older than 3.2, and a reconnect helper for
  dropped connections.

## About

Ghostty is a terminal emulator that differentiates itself by being
fast, feature-rich, and native. While there are many excellent terminal
emulators available, they all force you to choose between speed,
features, or native UIs. Ghostty provides all three.

**`libghostty`** is a cross-platform, zero-dependency C and Zig library
for building terminal emulators or utilizing terminal functionality
(such as style parsing). Anyone can use `libghostty` to build a terminal
emulator or embed a terminal into their own applications. See
[Ghostling](https://github.com/ghostty-org/ghostling) for a minimal complete project
example or the [`examples` directory](https://github.com/ghostty-org/ghostty/tree/main/example)
for smaller examples of using `libghostty` in C and Zig.

For more details, see [About Ghostty](https://ghostty.org/docs/about).

## Download

See the [download page](https://ghostty.org/download) on the Ghostty website.

## Documentation

See the [documentation](https://ghostty.org/docs) on the Ghostty website.

## Contributing and Developing

If you have any ideas, issues, etc. regarding Ghostty, or would like to
contribute to Ghostty through pull requests, please check out our
["Contributing to Ghostty"](CONTRIBUTING.md) document. Those who would like
to get involved with Ghostty's development as well should also read the
["Developing Ghostty"](HACKING.md) document for more technical details.

## Roadmap and Status

Ghostty is stable and in use by millions of people and machines daily.

The high-level ambitious plan for the project, in order:

|  #  | Step                                                    | Status |
| :-: | ------------------------------------------------------- | :----: |
|  1  | Standards-compliant terminal emulation                  |   ✅   |
|  2  | Competitive performance                                 |   ✅   |
|  3  | Rich windowing features -- multi-window, tabbing, panes |   ✅   |
|  4  | Native Platform Experiences                             |   ✅   |
|  5  | Cross-platform `libghostty` for Embeddable Terminals    |   ✅   |
|  6  | Ghostty-only Terminal Control Sequences                 |   ❌   |

Additional details for each step in the big roadmap below:

#### Standards-Compliant Terminal Emulation

Ghostty implements all of the regularly used control sequences and
can run every mainstream terminal program without issue. For legacy sequences,
we've done a [comprehensive xterm audit](https://github.com/ghostty-org/ghostty/issues/632)
comparing Ghostty's behavior to xterm and building a set of conformance
test cases.

In addition to legacy sequences (what you'd call real "terminal" emulation),
Ghostty also supports more modern sequences than almost any other terminal
emulator. These features include things like the Kitty graphics protocol,
Kitty image protocol, clipboard sequences, synchronized rendering,
light/dark mode notifications, and many, many more.

We believe Ghostty is one of the most compliant and feature-rich terminal
emulators available.

Terminal behavior is partially a de jure standard
(i.e. [ECMA-48](https://ecma-international.org/publications-and-standards/standards/ecma-48/))
but mostly a de facto standard as defined by popular terminal emulators
worldwide. Ghostty takes the approach that our behavior is defined by
(1) standards, if available, (2) xterm, if the feature exists, (3)
other popular terminals, in that order. This defines what the Ghostty project
views as a "standard."

#### Competitive Performance

Ghostty is generally in the same performance category as the other highest
performing terminal emulators.

"The same performance category" means that Ghostty is much faster than
traditional or "slow" terminals and is within an unnoticeable margin of the
well-known "fast" terminals. For example, Ghostty and Alacritty are usually within
a few percentage points of each other on various benchmarks, but are both
something like 100x faster than Terminal.app and iTerm. However, Ghostty
is much more feature rich than Alacritty and has a much more native app
experience.

This performance is achieved through high-level architectural decisions and
low-level optimizations. At a high-level, Ghostty has a multi-threaded
architecture with a dedicated read thread, write thread, and render thread
per terminal. Our renderer uses OpenGL on Linux and Metal on macOS.
Our read thread has a heavily optimized terminal parser that leverages
CPU-specific SIMD instructions. Etc.

#### Rich Windowing Features

The Mac and Linux (build with GTK) apps support multi-window, tabbing, and
splits with additional features such as tab renaming, coloring, etc. These
features allow for a higher degree of organization and customization than
single-window terminals.

#### Native Platform Experiences

Ghostty is a cross-platform terminal emulator but we don't aim for a
least-common-denominator experience. There is a large, shared core written
in Zig but we do a lot of platform-native things:

- The macOS app is a true SwiftUI-based application with all the things you
  would expect such as real windowing, menu bars, a settings GUI, etc.
- macOS uses a true Metal renderer with CoreText for font discovery.
- macOS supports AppleScript, Apple Shortcuts (AppIntents), etc.
- The Linux app is built with GTK.
- The Linux app integrates deeply with systemd if available for things
  like always-on, new windows in a single instance, cgroup isolation, etc.

Our goal with Ghostty is for users of whatever platform they run Ghostty
on to think that Ghostty was built for their platform first and maybe even
exclusively. We want Ghostty to feel like a native app on every platform,
for the best definition of "native" on each platform.

#### Cross-platform `libghostty` for Embeddable Terminals

In addition to being a standalone terminal emulator, Ghostty is a
C-compatible library for embedding a fast, feature-rich terminal emulator
in any 3rd party project. This library is called `libghostty`.

Due to the scope of this project, we're breaking libghostty down into
separate libraries, starting with `libghostty-vt`. The goal of
this project is to focus on parsing terminal sequences and maintaining
terminal state. This is covered in more detail in this
[blog post](https://mitchellh.com/writing/libghostty-is-coming).

`libghostty-vt` is already available and usable today for Zig and C and
is compatible for macOS, Linux, Windows, and WebAssembly. The functionality
is extremely stable (since its been proven in Ghostty GUI for a long time),
but the API signatures are still in flux.

`libghostty` is already heavily in use. See [`examples`](https://github.com/ghostty-org/ghostty/tree/main/example)
for small examples of using `libghostty` in C and Zig or the
[Ghostling](https://github.com/ghostty-org/ghostling) project for a
complete example. See [awesome-libghostty](https://github.com/Uzaaft/awesome-libghostty)
for a list of projects and resources related to `libghostty`.

We haven't tagged libghostty with a version yet and we're still working
on a better docs experience, but our [Doxygen website](https://libghostty.tip.ghostty.org/)
is a good resource for the C API.

#### Ghostty-only Terminal Control Sequences

We want and believe that terminal applications can and should be able
to do so much more. We've worked hard to support a wide variety of modern
sequences created by other terminal emulators towards this end, but we also
want to fill the gaps by creating our own sequences.

We've been hesitant to do this up until now because we don't want to create
more fragmentation in the terminal ecosystem by creating sequences that only
work in Ghostty. But, we do want to balance that with the desire to push the
terminal forward with stagnant standards and the slow pace of change in the
terminal ecosystem.

We haven't done any of this yet.

## Crash Reports

Ghostty has a built-in crash reporter that will generate and save crash
reports to disk. The crash reports are saved to the `$XDG_STATE_HOME/ghostty/crash`
directory. If `$XDG_STATE_HOME` is not set, the default is `~/.local/state`.
**Crash reports are _not_ automatically sent anywhere off your machine.**

Crash reports are only generated the next time Ghostty is started after a
crash. If Ghostty crashes and you want to generate a crash report, you must
restart Ghostty at least once. You should see a message in the log that a
crash report was generated.

> [!NOTE]
>
> Use the `ghostty +crash-report` CLI command to get a list of available crash
> reports. A future version of Ghostty will make the contents of the crash
> reports more easily viewable through the CLI and GUI.

Crash reports end in the `.ghosttycrash` extension. The crash reports are in
[Sentry envelope format](https://develop.sentry.dev/sdk/envelopes/). You can
upload these to your own Sentry account to view their contents, but the format
is also publicly documented so any other available tools can also be used.
The `ghostty +crash-report` CLI command can be used to list any crash reports.
A future version of Ghostty will show you the contents of the crash report
directly in the terminal.

To send the crash report to the Ghostty project, you can use the following
CLI command using the [Sentry CLI](https://docs.sentry.io/cli/installation/):

```shell-session
SENTRY_DSN=https://e914ee84fd895c4fe324afa3e53dac76@o4507352570920960.ingest.us.sentry.io/4507850923638784 sentry-cli send-envelope --raw <path to ghostty crash>
```

> [!WARNING]
>
> The crash report can contain sensitive information. The report doesn't
> purposely contain sensitive information, but it does contain the full
> stack memory of each thread at the time of the crash. This information
> is used to rebuild the stack trace but can also contain sensitive data
> depending on when the crash occurred.
