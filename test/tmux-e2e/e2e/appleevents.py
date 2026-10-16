"""A tiny Apple Event client that addresses an application by *process id*.

`osascript`/JXA resolve `Application(pid)` back to a bundle identifier and
then talk to whichever instance LaunchServices picks — with the user's own
Ghostty running, that is the wrong one. Building the events ourselves with
`NSAppleEventDescriptor.descriptorWithProcessIdentifier_` guarantees that
the launched test instance is the only one we ever touch.

Only what the harness needs is implemented: object specifiers (by unique ID,
by property, every element), `get`, and sending arbitrary commands using the
four-character codes from macos/Ghostty.sdef.
"""

from __future__ import annotations

import sys
from typing import Any

from Foundation import NSAppleEventDescriptor  # type: ignore[import-not-found]

from .util import HarnessError

# Error numbers worth translating.
ERR_NOT_AUTHORIZED = -1743  # errAEEventNotPermitted (TCC Automation)
ERR_PROC_NOT_FOUND = -600  # procNotFound
ERR_NO_SUCH_OBJECT = -1728  # errAENoSuchObject

kAutoGenerateReturnID = -1
kAnyTransactionID = 0
SEND_OPTIONS = 0x3 | 0x10  # kAEWaitReply | kAECanInteract (lets TCC prompt)


def fcc(code: str) -> int:
    """Four-character code -> OSType."""
    assert len(code) == 4, code
    return int.from_bytes(code.encode("mac_roman"), "big")


class AppleEventError(RuntimeError):
    def __init__(self, message: str, number: int = 0) -> None:
        super().__init__(f"{message} ({number})" if number else message)
        self.number = number


# -- descriptors ---------------------------------------------------------------

D = NSAppleEventDescriptor


def text(value: str) -> Any:
    return D.descriptorWithString_(value)


def enum(code: str) -> Any:
    return D.descriptorWithEnumCode_(fcc(code))


def record(**fields: Any) -> Any:
    """An AE record keyed by four-character codes (`record(GScC=text('sh'))`)."""
    rec = D.recordDescriptor()
    for key, value in fields.items():
        rec.setDescriptor_forKeyword_(value, fcc(key.ljust(4)))
    return rec


APP = D.nullDescriptor()


def _specifier(want: str, form: str, seld: Any, container: Any) -> Any:
    rec = D.recordDescriptor()
    rec.setDescriptor_forKeyword_(D.descriptorWithTypeCode_(fcc(want)), fcc("want"))
    rec.setDescriptor_forKeyword_(D.descriptorWithEnumCode_(fcc(form)), fcc("form"))
    rec.setDescriptor_forKeyword_(seld, fcc("seld"))
    rec.setDescriptor_forKeyword_(container, fcc("from"))
    spec = rec.coerceToDescriptorType_(fcc("obj "))
    if spec is None:
        raise HarnessError("could not build an AppleEvent object specifier")
    return spec


def by_id(cls: str, unique_id: str, container: Any = APP) -> Any:
    return _specifier(cls, "ID  ", text(unique_id), container)


def every(cls: str, container: Any = APP) -> Any:
    all_ = D.descriptorWithDescriptorType_bytes_length_(fcc("abso"), fcc("all ").to_bytes(4, sys.byteorder), 4)
    return _specifier(cls, "indx", all_, container)


def prop(code: str, container: Any = APP) -> Any:
    return _specifier("prop", "prop", D.descriptorWithTypeCode_(fcc(code.ljust(4))), container)


def to_python(desc: Any) -> Any:
    """Convert a reply descriptor to Python; object specifiers stay descriptors."""
    if desc is None:
        return None
    t = desc.descriptorType()
    if t == fcc("list"):
        return [to_python(desc.descriptorAtIndex_(i)) for i in range(1, desc.numberOfItems() + 1)]
    if t in (fcc("utxt"), fcc("TEXT"), fcc("utf8")):
        return desc.stringValue()
    if t in (fcc("long"), fcc("shor"), fcc("comp")):
        return int(desc.int32Value())
    if t in (fcc("bool"), fcc("true"), fcc("fals")):
        return bool(desc.booleanValue())
    if t in (fcc("doub"), fcc("sing")):
        return float(desc.doubleValue())
    if t == fcc("null"):
        return None
    return desc


# -- client --------------------------------------------------------------------


class AppleEventClient:
    def __init__(self, pid: int, timeout: float = 15.0) -> None:
        self.pid = pid
        self.timeout = timeout
        self.target = D.descriptorWithProcessIdentifier_(pid)

    def send(self, event: str, direct: Any = None, **params: Any) -> Any:
        """Send `event` (8-char code, e.g. "GhstInTx") and return the result.

        Keyword params are keyed by their four-character sdef codes.
        """
        ev = D.appleEventWithEventClass_eventID_targetDescriptor_returnID_transactionID_(
            fcc(event[:4]), fcc(event[4:]), self.target, kAutoGenerateReturnID, kAnyTransactionID
        )
        if direct is not None:
            ev.setParamDescriptor_forKeyword_(direct, fcc("----"))
        for key, value in params.items():
            if value is not None:
                ev.setParamDescriptor_forKeyword_(value, fcc(key.ljust(4)))

        reply, error = ev.sendEventWithOptions_timeout_error_(SEND_OPTIONS, self.timeout, None)
        if reply is None:
            code = int(error.code()) if error is not None else 0
            self._raise(code, str(error.localizedDescription()) if error is not None else "send failed")
        errn = reply.paramDescriptorForKeyword_(fcc("errn"))
        if errn is not None and errn.int32Value() != 0:
            errs = reply.paramDescriptorForKeyword_(fcc("errs"))
            self._raise(int(errn.int32Value()), errs.stringValue() if errs is not None else "AppleEvent error")
        return to_python(reply.paramDescriptorForKeyword_(fcc("----")))

    def get(self, specifier: Any) -> Any:
        return self.send("coregetd", specifier)

    def _raise(self, number: int, message: str) -> None:
        if number == ERR_NOT_AUTHORIZED:
            raise HarnessError(
                "macOS denied Automation (Apple Events) access to Ghostty (-1743).\n"
                "  Allow it in System Settings > Privacy & Security > Automation for the\n"
                "  app running this script (your terminal), then re-run. The harness does\n"
                "  not try to bypass TCC."
            )
        if number == ERR_PROC_NOT_FOUND:
            # Also seen briefly while the app is still starting up.
            message = f"no scriptable process with pid {self.pid}"
        raise AppleEventError(message, number)
