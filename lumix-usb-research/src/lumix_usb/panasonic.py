"""Panasonic LUMIX vendor protocol (transport-independent).

Every function here only needs a `Transport` (opcode + params + data phase),
so this module maps directly onto ImageCaptureCore's requestSendPTPCommand.
See docs/command-reference.md for the verification status of each item.
"""
from __future__ import annotations

import struct
import time
from dataclasses import dataclass, field
from typing import Optional

from .ptp import OC, RC, DeviceInfo, Event, ObjectInfo, PTPError, Response, StorageInfo
from .transport.base import Transport


class POC:
    """Panasonic vendor operation codes."""
    OpenSession = 0x9102          # p1 = 0x00010001
    CloseSession = 0x9103         # p1 = 0x00010001
    GetExtDeviceId = 0x9104
    GetPropertyDesc = 0x9108      # "ListProperty": current value + allowed values
    AckEvent = 0x9401             # data-in; p1 = param1 of event 0xC101
    GetProperty = 0x9402          # data-in; p1 = property (group) code
    SetProperty = 0x9403          # data-out; p1 = property code
    Release = 0x9404              # p1 = 0x03000011 (shutter)
    AFAE = 0x9405                 # p1 = 0x0300002x
    GetCaptureTarget = 0x940A     # data-in; p1 = 0x08000090
    SetCaptureTarget = 0x940B     # data-out; p1 = 0
    MovieRecControl = 0x940C
    Liveview = 0x9412             # p1 = 0x0D000010 start / 0x0D000011 stop
    GetStatus = 0x9414            # data-in; liveview params, recording status, ...
    SetLiveviewParams = 0x9415    # data-out
    ManualFocusDrive = 0x9416
    LiveviewImage = 0x9706        # data-in: TLV header + JPEG


class PEC:
    """Panasonic event codes (advertised in DeviceInfo.EventsSupported)."""
    AckRequired = 0xC101          # host answers with 0x9401(param1)
    PropChanged = 0xC102          # p1 = property group code
    ObjectAdded = 0xC108          # p1 = object handle (SD card)
    ObjectAddedSDRAM = 0xC109     # p1 = object handle (camera RAM, capture target = PC)


SESSION_PARAM = 0x00010001
LV_START, LV_STOP = 0x0D000010, 0x0D000011
LV_CURRENT, LV_OPTIONS = 0x0D800011, 0x0D800012
RELEASE_SHUTTER = 0x03000011
AF_LOCK_AE, AF_LOCK_AF, AF_LOCK_AFAE, AF_ONESHOT, AF_LOCK_CLEAR = (
    0x03000021, 0x03000022, 0x03000023, 0x03000024, 0x03000025)
CAPTURE_TARGET_PROP = 0x08000091
CAPTURE_TARGET_QUERY = 0x08000090


class Target:
    SD = 0
    PC = 1        # "SDRAM": image is held in camera RAM and announced with 0xC109
    BOTH = 2


# Property codes (group code; *_Param is the settable member).
PROPS = {
    "photo_style": 0x02000010, "iso": 0x02000020, "iso_param": 0x02000021,
    "iso_upper_limit": 0x02000022, "shutter": 0x02000030, "shutter_param": 0x02000031,
    "aperture": 0x02000040, "aperture_param": 0x02000041,
    "white_balance": 0x02000050, "white_balance_param": 0x02000051,
    "wb_kelvin": 0x02000052, "exposure_comp": 0x02000060, "exposure_comp_param": 0x02000061,
    "af_area": 0x02000070, "af_mode": 0x02000071, "camera_mode": 0x02000080,
    "drive_mode": 0x02000081, "mode_pos": 0x02000082, "image_mode": 0x020000A0,
    "image_quality": 0x020000A2, "image_aspect": 0x020000A3, "metering": 0x020000B0,
}


def parse_tlv(data: bytes, offset: int = 0) -> dict[int, bytes]:
    """Panasonic property/status payloads: repeated {u32 code, u32 size, size bytes}."""
    out: dict[int, bytes] = {}
    while offset + 8 <= len(data):
        code, size = struct.unpack_from("<II", data, offset)
        if offset + 8 + size > len(data):
            break
        out[code] = data[offset + 8:offset + 8 + size]
        offset += 8 + size
    return out


def tlv_value(body: bytes) -> int:
    if len(body) == 1:
        return body[0]
    if len(body) == 2:
        return struct.unpack("<H", body)[0]
    if len(body) == 4:
        return struct.unpack("<I", body)[0]
    raise ValueError(f"unexpected value size {len(body)}")


@dataclass
class LiveviewSetting:
    height: int
    width: int
    frame_kb: int      # max JPEG size hint (units of KiB, inferred)
    fps: int

    def pack(self) -> bytes:
        return struct.pack("<IIHHHH", LV_CURRENT, 8, self.height, self.width, self.frame_kb, self.fps)

    def __str__(self) -> str:
        return f"{self.width}x{self.height}@{self.fps} ({self.frame_kb})"


@dataclass
class LiveviewFrame:
    raw: bytes
    jpeg: bytes
    tags: dict[int, bytes] = field(default_factory=dict)
    histogram: bytes = b""
    roll: Optional[float] = None
    pitch: Optional[float] = None


def parse_liveview(data: bytes) -> LiveviewFrame:
    """Decode a 0x9706 payload. Verified on DC-S5M2 fw 3.6.

    Layout: TLV entries tagged 0x17xxxxxx, each body prefixed by u16 1, u16 1;
    an untagged region; then a baseline JPEG running to the end of the payload.
    0x17000001 body[4:8] = JPEG offset. 0x17000002 body[4:8] = JPEG length + 12
    (observed), so the payload end is used instead.
    """
    tags = {}
    off = 0
    while off + 8 <= len(data):
        tag, size = struct.unpack_from("<II", data, off)
        if tag >> 24 != 0x17:
            break
        tags[tag] = data[off + 8:off + 8 + size]
        off += 8 + size
    jpeg_off = None
    if 0x17000001 in tags and len(tags[0x17000001]) >= 8:
        jpeg_off = struct.unpack_from("<I", tags[0x17000001], 4)[0]
    if jpeg_off is None or data[jpeg_off:jpeg_off + 2] != b"\xff\xd8":
        jpeg_off = data.find(b"\xff\xd8\xff")
    if jpeg_off < 0:
        raise ValueError("no JPEG in liveview payload")
    frame = LiveviewFrame(data, data[jpeg_off:], tags)
    h = tags.get(0x17000003)
    if h and len(h) >= 16:
        n = struct.unpack_from("<I", h, 12)[0]
        frame.histogram = h[16:16 + n]
    lv = tags.get(0x17000005)
    if lv and len(lv) >= 8:
        roll, pitch = struct.unpack_from("<hh", lv, 4)
        frame.roll, frame.pitch = roll / 10, pitch / 10
    return frame


class Camera:
    """High-level S5II controller built only on Transport.execute()."""

    def __init__(self, transport: Transport, auto_ack: bool = True):
        import queue
        import threading
        self.t = transport
        self.events: "queue.Queue[Event]" = queue.Queue()
        self.event_log: list[Event] = []
        self.auto_ack = auto_ack
        self._stop = threading.Event()
        self._pump = threading.Thread(target=self._event_pump, daemon=True)
        self._pump.start()
        self.vendor_session = False
        self.liveview_on = False

    # -- events -------------------------------------------------------------
    def _event_pump(self) -> None:
        while not self._stop.is_set():
            ev = self.t.wait_event(0.1)
            if ev is None or ev.code < 0:
                continue
            self.event_log.append(ev)
            if self.auto_ack and ev.code == PEC.AckRequired and ev.params:
                try:
                    r = self.t.read(POC.AckEvent, ev.params[0])
                    self.t.log_note(kind="ack", param=f"0x{ev.params[0]:08X}",
                                    rc=f"0x{r.code:04X}", data=r.data.hex())
                except Exception as e:
                    self.t.log_note(kind="ack_error", error=repr(e))
            self.events.put(ev)

    def drain_events(self) -> list[Event]:
        out = []
        while not self.events.empty():
            out.append(self.events.get_nowait())
        return out

    def wait_event(self, codes: set[int], timeout: float) -> Optional[Event]:
        import queue
        deadline = time.monotonic() + timeout
        while (left := deadline - time.monotonic()) > 0:
            try:
                ev = self.events.get(timeout=left)
            except queue.Empty:
                return None
            if ev.code in codes:
                return ev
        return None

    # -- session ------------------------------------------------------------
    def device_info(self) -> DeviceInfo:
        return DeviceInfo.parse(self.t.read(OC.GetDeviceInfo).check().data)

    def connect(self) -> Response:
        r = self.t.command(POC.OpenSession, SESSION_PARAM).check()
        self.vendor_session = True
        return r

    def disconnect(self) -> None:
        try:
            if self.liveview_on:
                self.liveview_stop()
            if self.vendor_session:
                self.t.command(POC.CloseSession, SESSION_PARAM)
                self.vendor_session = False
        finally:
            self._stop.set()
            self._pump.join(1)
            self.t.close()

    # -- properties ---------------------------------------------------------
    def get_property(self, code: int) -> dict[int, bytes]:
        return parse_tlv(self.t.read(POC.GetProperty, code).check().data)

    def get_value(self, code: int) -> int:
        tl = self.get_property(code)
        if code not in tl:
            raise KeyError(f"0x{code:08X} not in reply {[hex(k) for k in tl]}")
        return tlv_value(tl[code])

    def get_property_desc(self, code: int, value_size: int) -> tuple[int, list[int], bytes]:
        """0x9108: returns (current, allowed values, raw). Layout per libgphoto2/tethr."""
        data = self.t.read(POC.GetPropertyDesc, code).check().data
        if len(data) < 8:
            raise ValueError("empty property desc")
        header_len = struct.unpack_from("<I", data, 4)[0]
        fmt = {1: "<B", 2: "<H", 4: "<I"}[value_size]
        pos = header_len * 4 + 8
        cur = struct.unpack_from(fmt, data, pos)[0]
        pos += value_size
        n = struct.unpack_from("<I", data, pos)[0]
        pos += 4
        vals = [struct.unpack_from(fmt, data, pos + i * value_size)[0] for i in range(n)]
        return cur, vals, data

    def set_property(self, code: int, value: int, size: int) -> Response:
        fmt = {1: "<B", 2: "<H", 4: "<I"}[size]
        payload = struct.pack("<II", code, size) + struct.pack(fmt, value)
        return self.t.write(POC.SetProperty, payload, code)

    def get_capture_target(self) -> int:
        tl = parse_tlv(self.t.read(POC.GetCaptureTarget, CAPTURE_TARGET_QUERY).check().data)
        return tlv_value(tl[CAPTURE_TARGET_PROP])

    def set_capture_target(self, target: int) -> Response:
        payload = struct.pack("<IIH", CAPTURE_TARGET_PROP, 2, target)
        return self.t.write(POC.SetCaptureTarget, payload, 0).check()

    # -- liveview -----------------------------------------------------------
    def liveview_settings(self) -> tuple[LiveviewSetting, list[LiveviewSetting]]:
        cur = self.t.read(POC.GetStatus, LV_CURRENT).check().data
        opts = self.t.read(POC.GetStatus, LV_OPTIONS).check().data
        current = LiveviewSetting(*struct.unpack_from("<HHHH", cur, 8))
        count, ssize = struct.unpack_from("<HH", opts, 8)
        options = [LiveviewSetting(*struct.unpack_from("<HHHH", opts, 12 + i * ssize))
                   for i in range(count)]
        return current, options

    def set_liveview_setting(self, s: LiveviewSetting) -> Response:
        return self.t.write(POC.SetLiveviewParams, s.pack(), LV_CURRENT).check()

    def liveview_start(self) -> Response:
        r = self.t.command(POC.Liveview, LV_START).check()
        self.liveview_on = True
        return r

    def liveview_stop(self) -> Response:
        r = self.t.command(POC.Liveview, LV_STOP)
        self.liveview_on = False
        return r

    def liveview_frame(self, retries: int = 25) -> Optional[LiveviewFrame]:
        for _ in range(retries):
            r = self.t.read(POC.LiveviewImage)
            if r.ok and r.data:
                return parse_liveview(r.data)
            if r.code != RC.DeviceBusy and not (r.ok and not r.data):
                raise PTPError(POC.LiveviewImage, r.code)
            time.sleep(0.02)
        return None

    # -- focus / capture ------------------------------------------------------
    def autofocus(self) -> Response:
        """One-shot AF (0x9405 / 0x03000024)."""
        return self.t.command(POC.AFAE, AF_ONESHOT)

    def af_control(self, param: int) -> Response:
        return self.t.command(POC.AFAE, param)

    def release(self) -> Response:
        return self.t.command(POC.Release, RELEASE_SHUTTER)

    def capture(self, timeout: float = 15.0, want_formats=(0x3801,),
                retry_general_error: bool = True) -> dict:
        """Fire the shutter and wait for the new object(s).

        Returns {"release_rc", "events", "objects": [(handle, ObjectInfo)], "t_*"}.
        """
        self.drain_events()
        t0 = time.perf_counter()
        r = self.release()
        if r.code == RC.GeneralError and retry_general_error:
            time.sleep(1.0)              # tethr: refused briefly after AF etc.
            r = self.release()
        t_release = time.perf_counter() - t0
        result = {"release_rc": r.code, "events": [], "objects": [], "t_release": t_release}
        if not r.ok:
            return result
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            ev = self.wait_event({PEC.ObjectAdded, PEC.ObjectAddedSDRAM, 0x4002},
                                 deadline - time.monotonic())
            if ev is None:
                break
            result["events"].append(ev)
            handle = ev.params[0] if ev.params else 0
            time.sleep(0.05)             # libgphoto2: object not readable immediately
            try:
                info = self.object_info(handle)
            except PTPError:
                continue
            if info.format == 0x3001:    # new folder, keep waiting
                continue
            result["objects"].append((handle, info))
            result.setdefault("t_object", time.perf_counter() - t0)
            if info.format in want_formats:
                break
        result["t_done"] = time.perf_counter() - t0
        return result

    # -- storage / objects ------------------------------------------------------
    def storage_ids(self) -> list[int]:
        data = self.t.read(OC.GetStorageIDs).check().data
        n = struct.unpack_from("<I", data)[0]
        return list(struct.unpack_from(f"<{n}I", data, 4))

    def storage_info(self, sid: int) -> StorageInfo:
        return StorageInfo.parse(self.t.read(OC.GetStorageInfo, sid).check().data)

    def object_handles(self, sid: int = 0xFFFFFFFF, fmt: int = 0, parent: int = 0) -> list[int]:
        data = self.t.read(OC.GetObjectHandles, sid, fmt, parent).check().data
        n = struct.unpack_from("<I", data)[0]
        return list(struct.unpack_from(f"<{n}I", data, 4))

    def object_info(self, handle: int) -> ObjectInfo:
        r = self.t.read(OC.GetObjectInfo, handle)
        if not r.ok:
            raise PTPError(OC.GetObjectInfo, r.code)
        return ObjectInfo.parse(r.data)

    def download(self, handle: int) -> bytes:
        return self.t.read(OC.GetObject, handle).check().data

    def download_partial(self, handle: int, size: int, chunk: int = 4 << 20) -> bytes:
        buf = bytearray()
        while len(buf) < size:
            n = min(chunk, size - len(buf))
            buf += self.t.read(OC.GetPartialObject, handle, len(buf), n).check().data
        return bytes(buf)
