"""Transport abstraction.

The contract deliberately mirrors Apple ImageCaptureCore's
`ICCameraDevice.requestSendPTPCommand(_:outData:completion:)`: the caller
supplies an operation code, up to 5 u32 parameters and an optional outgoing
data phase; the transport returns the response code, response parameters and
any incoming data phase. Session handling and transaction IDs belong to the
transport (WPD and ImageCaptureCore both own the PTP session themselves).
"""
from __future__ import annotations

import json
import queue
import threading
import time
from abc import ABC, abstractmethod
from typing import Callable, Optional

from ..ptp import Event, Response, rc_name


class DataPhase:
    NONE = "none"
    READ = "read"     # device -> host
    WRITE = "write"   # host -> device


class Transport(ABC):
    """One open connection to one camera."""

    def __init__(self) -> None:
        self.events: "queue.Queue[Event]" = queue.Queue()
        self._lock = threading.RLock()          # serialize transactions
        self._log: Optional[Callable[[dict], None]] = None

    # -- to implement -----------------------------------------------------
    @abstractmethod
    def _execute(self, opcode: int, params: list[int], phase: str,
                 out_data: bytes | None) -> Response: ...

    @abstractmethod
    def close(self) -> None: ...

    # -- public -----------------------------------------------------------
    def execute(self, opcode: int, params: list[int] | None = None,
                phase: str = DataPhase.NONE, out_data: bytes | None = None) -> Response:
        params = list(params or [])
        if len(params) > 5:
            raise ValueError("PTP allows at most 5 parameters")
        if phase == DataPhase.WRITE and out_data is None:
            raise ValueError("write phase needs out_data")
        with self._lock:
            t0 = time.perf_counter()
            resp = self._execute(opcode, params, phase, out_data)
            dt = time.perf_counter() - t0
        if self._log:
            self._log({
                "t": time.time(), "dt_ms": round(dt * 1000, 2), "op": f"0x{opcode:04X}",
                "params": [f"0x{p:08X}" for p in params], "phase": phase,
                "out_len": len(out_data) if out_data else 0,
                "out_head": out_data[:64].hex() if out_data else "",
                "rc": f"0x{resp.code:04X}", "rc_name": rc_name(resp.code),
                "rparams": [f"0x{p:08X}" for p in resp.params],
                "in_len": len(resp.data), "in_head": resp.data[:64].hex(),
            })
        return resp

    def read(self, opcode: int, *params: int) -> Response:
        return self.execute(opcode, list(params), DataPhase.READ)

    def write(self, opcode: int, data: bytes, *params: int) -> Response:
        return self.execute(opcode, list(params), DataPhase.WRITE, data)

    def command(self, opcode: int, *params: int) -> Response:
        return self.execute(opcode, list(params), DataPhase.NONE)

    def wait_event(self, timeout: float) -> Optional[Event]:
        try:
            return self.events.get(timeout=timeout)
        except queue.Empty:
            return None

    def drain_events(self) -> list[Event]:
        out = []
        while True:
            try:
                out.append(self.events.get_nowait())
            except queue.Empty:
                return out

    def set_jsonl_log(self, path: str) -> None:
        fh = open(path, "a", encoding="utf-8")
        lock = threading.Lock()

        def log(rec: dict) -> None:
            with lock:
                fh.write(json.dumps(rec) + "\n")
                fh.flush()
        self._log = log

    def log_note(self, **kw) -> None:
        if self._log:
            self._log({"t": time.time(), **kw})
