#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyobjc-framework-Quartz>=10", "pyobjc-framework-ApplicationServices>=10"]
# ///
"""End-to-end tests for tmux control mode (`tmux -CC`) in the Ghostty macOS app.

See README.md in this directory. Typical use:

    test/tmux-e2e/run.py                     # all scenarios against zig-out/Ghostty.app
    test/tmux-e2e/run.py -k gui_ -k attach   # only matching scenarios
    test/tmux-e2e/run.py --app /Applications/Ghostty.app --list
"""

from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
import time
import traceback
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from e2e import util  # noqa: E402
from e2e.context import Context  # noqa: E402
from e2e.ghostty import AppleScriptError, GhosttyApp  # noqa: E402
from e2e.scenarios import SCENARIOS, Scenario  # noqa: E402
from e2e.tmux import Tmux  # noqa: E402
from e2e.util import CheckFailed, HarnessError, Skip  # noqa: E402
from e2e.windows import screenshot  # noqa: E402

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent

COLORS = {"PASS": "\033[32m", "FAIL": "\033[31m", "ERROR": "\033[31m", "SKIP": "\033[33m"}


def status_text(status: str) -> str:
    if not sys.stdout.isatty():
        return status
    return f"{COLORS.get(status, '')}{status}\033[0m"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--app", type=Path, default=REPO / "zig-out" / "Ghostty.app", help="app bundle to test")
    p.add_argument(
        "-k", dest="filters", action="append", default=[], help="run scenarios whose name contains this (repeatable)"
    )
    p.add_argument("--list", action="store_true", help="list scenarios and exit")
    p.add_argument("--timeout", type=float, default=10.0, help="per-expectation timeout in seconds (default 10)")
    p.add_argument("--out", type=Path, help="output dir for logs/screenshots (default test/tmux-e2e/out/<timestamp>)")
    p.add_argument("-x", "--fail-fast", action="store_true", help="stop at the first failure")
    p.add_argument("--keep-workdir", action="store_true", help="don't delete the temporary config/TMPDIR")
    p.add_argument("-v", "--verbose", action="store_true", help="log every tmux/AppleScript step")
    return p.parse_args()


def select(filters: list[str]) -> list[Scenario]:
    if not filters:
        return list(SCENARIOS)
    return [s for s in SCENARIOS if any(f in s.name for f in filters)]


def run_one(s: Scenario, app: GhosttyApp, workdir: Path, out_dir: Path, timeout: float) -> tuple[str, str]:
    scenario_dir = workdir / s.name
    scenario_dir.mkdir()
    tmux = Tmux(scenario_dir)
    ctx = Context(app=app, tmux=tmux, out_dir=out_dir, timeout=timeout)
    try:
        app.close_all_windows(timeout=timeout)
        if not app.ensure_active():
            print("(app could not become active; focus checks will fail) ", end="", flush=True)
        s.func(ctx)
        if not app.alive():
            raise CheckFailed("Ghostty went away during the scenario")
        return "PASS", ""
    except Skip as exc:
        return "SKIP", str(exc)
    except (CheckFailed, AppleScriptError) as exc:
        detail = str(exc)
        if app.alive():
            shots = screenshot(app.pid, out_dir, s.name)
            if shots:
                detail += "\n  screenshots: " + ", ".join(map(str, shots))
        else:
            # Its going away is what failed the check, most likely, so
            # say so first: the check's own message guesses at a cause
            # inside the app (e.g. "the keys reached tmux" for a control
            # client that went away because the app did).
            detail = f"Ghostty is not running anymore: {app.exit_reason()}\n  then: {detail}"
        return "FAIL", detail
    except HarnessError:
        raise
    except Exception:  # noqa: BLE001 - report harness bugs without aborting the run
        return "ERROR", traceback.format_exc()
    finally:
        try:
            ctx.teardown()
        except Exception as exc:  # noqa: BLE001
            util.log(f"teardown: {exc}")
        tmux.kill_server()


def main() -> int:
    args = parse_args()
    util.VERBOSE = args.verbose
    scenarios = select(args.filters)

    if args.list:
        width = max(len(s.name) for s in SCENARIOS)
        for s in scenarios:
            print(f"{s.name:<{width}}  {s.doc}")
        return 0
    if not scenarios:
        print(f"no scenarios match {args.filters}", file=sys.stderr)
        return 2

    out_dir = (args.out or HERE / "out" / datetime.now().strftime("%Y%m%d-%H%M%S")).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    workdir = Path(tempfile.mkdtemp(prefix="ghostty-tmux-e2e-"))
    app: GhosttyApp | None = None
    results: list[tuple[str, str, str, float]] = []
    aborted = ""

    try:
        app = GhosttyApp(args.app, workdir, out_dir / "ghostty.log")
        print(f"app:    {app.bundle} ({app.bundle_id})")
        print(f"output: {out_dir}")
        app.launch()
        print(f"pid:    {app.pid}, version {app.version()}\n")

        for s in scenarios:
            if not app.alive():
                print(f"  Ghostty is not running ({app.exit_reason()}); relaunching for the next scenario")
                app.terminate()
                app.launch()
            print(f"{s.name} ...", end=" ", flush=True)
            start = time.monotonic()
            status, detail = run_one(s, app, workdir, out_dir, args.timeout)
            elapsed = time.monotonic() - start
            results.append((s.name, status, detail, elapsed))
            print(f"{status_text(status)} ({elapsed:.1f}s)")
            if detail:
                print("  " + detail.replace("\n", "\n  "))
            if args.fail_fast and status in ("FAIL", "ERROR"):
                break
    except HarnessError as exc:
        aborted = str(exc)
    except KeyboardInterrupt:
        aborted = "interrupted"
    finally:
        if app is not None:
            app.terminate()
        if args.keep_workdir:
            print(f"\nworkdir kept: {workdir}")
        else:
            shutil.rmtree(workdir, ignore_errors=True)

    print("\n" + "=" * 60)
    counts: dict[str, int] = {}
    for name, status, _, elapsed in results:
        counts[status] = counts.get(status, 0) + 1
        print(f"{status_text(status):<5}  {name} ({elapsed:.1f}s)")
    print("-" * 60)
    print(", ".join(f"{n} {k.lower()}" for k, n in sorted(counts.items())) or "nothing ran")
    if aborted:
        print(f"\nABORTED: {aborted}", file=sys.stderr)
        return 2
    return 1 if any(s in ("FAIL", "ERROR") for _, s, _, _ in results) else 0


if __name__ == "__main__":
    sys.exit(main())
