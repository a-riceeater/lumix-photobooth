"""Reconnect wrapper: re-establishes the session and camera state after a drop.

Transport-agnostic except for the `opener` callable, so the same policy can be
reused with an ImageCaptureCore transport.
"""
from __future__ import annotations

import time
from typing import Callable, Optional

from .panasonic import Camera, LiveviewSetting
from .transport.base import Transport


class ResilientCamera:
    """Observed on S5II/WPD (unplug, replug, power cycle; test_reconnect_1795666463):
    in-flight READ fails with HRESULT 0x8007001F, reopening fails with 0x800701B1,
    then the device is absent from enumeration until replugged. No
    WPD_EVENT_DEVICE_REMOVED was delivered before the failing transaction."""

    POLL_S = 0.5

    def __init__(self, opener: Callable[[], Transport], capture_target: Optional[int] = None,
                 liveview_setting: Optional[LiveviewSetting] = None, log=print):
        self.opener = opener
        self.capture_target = capture_target
        self.liveview_setting = liveview_setting
        self.want_liveview = False
        self.cam: Optional[Camera] = None
        self.log = log
        self.reconnects = 0
        self.outages: list[float] = []      # seconds from failure to session restored
        self._down_since: Optional[float] = None

    def _open(self) -> Camera:
        cam = Camera(self.opener())
        cam.connect()
        if self.capture_target is not None:
            cam.set_capture_target(self.capture_target)
        if self.liveview_setting is not None:
            cam.set_liveview_setting(self.liveview_setting)
        if self.want_liveview:
            cam.liveview_start()
            time.sleep(0.2)
        return cam

    def drop(self) -> None:
        if self.cam is not None:
            try:
                self.cam._stop.set()
                self.cam.t.close()
            except Exception:
                pass
        self.cam = None

    def ensure(self, timeout: float = 60.0) -> Camera:
        deadline = time.monotonic() + timeout
        while self.cam is None:
            try:
                self.cam = self._open()
                if self._down_since is not None:
                    self.outages.append(time.monotonic() - self._down_since)
                    self.log(f"[recovery] session restored after {self.outages[-1]:.2f}s")
                    self._down_since = None
            except Exception as e:
                if time.monotonic() > deadline:
                    raise
                self.log(f"[recovery] open failed: {e!r}; retrying in {self.POLL_S} s")
                time.sleep(self.POLL_S)
        return self.cam

    def call(self, fn: Callable[[Camera], object], retries: int = 1):
        """Run fn(camera); on a transport-level failure reconnect and retry."""
        for attempt in range(retries + 1):
            cam = self.ensure()
            try:
                return fn(cam)
            except Exception as e:
                if not _is_transport_error(e) or attempt == retries:
                    raise
                self.log(f"[recovery] transport error {e!r}; reconnecting")
                self.reconnects += 1
                self._down_since = time.monotonic()
                self.drop()

    def close(self) -> None:
        if self.cam:
            try:
                self.cam.disconnect()
            except Exception:
                pass
        self.cam = None


def _is_transport_error(e: Exception) -> bool:
    import comtypes
    from .ptp import PTPError
    if isinstance(e, PTPError):
        return False  # camera answered; protocol-level error
    return isinstance(e, (OSError, comtypes.COMError, ValueError, RuntimeError))
