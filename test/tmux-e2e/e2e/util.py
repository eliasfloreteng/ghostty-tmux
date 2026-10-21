"""Small shared helpers: polling, logging and harness-level exceptions."""

from __future__ import annotations

import sys
import time
from typing import Callable, TypeVar

T = TypeVar("T")

VERBOSE = False


class HarnessError(Exception):
    """The harness itself could not do its job (permissions, missing app, ...).

    This is distinct from a test assertion failing: it usually means every
    following scenario will fail the same way, so the runner aborts.
    """


class CheckFailed(AssertionError):
    """A scenario expectation was not met."""


class Skip(Exception):
    """A scenario (or part of it) cannot be verified automatically."""


def log(msg: str) -> None:
    if VERBOSE:
        print(f"    · {msg}", file=sys.stderr, flush=True)


def wait_until(
    predicate: Callable[[], T],
    *,
    timeout: float = 10.0,
    interval: float = 0.2,
    desc: str = "condition",
    describe_state: Callable[[], str] | None = None,
) -> T:
    """Poll `predicate` until it returns a truthy value and return that value.

    Exceptions raised by the predicate (other than HarnessError and Skip)
    count as "not yet" so that transient states (e.g. a terminal
    disappearing between listing it and reading its properties) don't abort
    the wait. A Skip, such as the Accessibility permission missing, is not
    transient: waiting cannot fix it, and it skips the scenario. On timeout a
    CheckFailed is raised, including the last exception and, if given, a
    description of the current state to make failures self-explanatory.
    """
    deadline = time.monotonic() + timeout
    last_exc: Exception | None = None
    while True:
        try:
            value = predicate()
            if value:
                return value
            last_exc = None
        except (HarnessError, Skip):
            raise
        except Exception as exc:  # noqa: BLE001 - see docstring
            last_exc = exc
        if time.monotonic() >= deadline:
            break
        time.sleep(interval)

    msg = f"timed out after {timeout:g}s waiting for {desc}"
    if last_exc is not None:
        msg += f"\n  last error: {type(last_exc).__name__}: {last_exc}"
    if describe_state is not None:
        try:
            msg += f"\n  state: {describe_state()}"
        except Exception as exc:  # noqa: BLE001
            msg += f"\n  state: <unavailable: {exc}>"
    raise CheckFailed(msg)


def check(cond: object, msg: str) -> None:
    if not cond:
        raise CheckFailed(msg)
