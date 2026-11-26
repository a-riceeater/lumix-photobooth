"""Windows Portable Devices transport (stock Microsoft MTP driver, no driver swap).

Raw PTP transactions go through the documented MTP vendor-extension commands
(WpdMtpExtensions.h): WPD_COMMAND_MTP_EXT_EXECUTE_COMMAND_* / READ_DATA /
WRITE_DATA / END_DATA_TRANSFER. Windows' MTP class driver owns the USB pipes,
the PTP session (it issues OpenSession itself) and the transaction IDs.

PTP interrupt-endpoint events are delivered by the driver through
IPortableDevice::Advise. Events the driver does not map to a WPD event arrive
as WPD_EVENT_MTP_VENDOR_EXTENDED_EVENTS with (event code << 16) in GUID Data1 and
the parameters in WPD_PROPERTY_MTP_EXT_EVENT_PARAMS.
"""
from __future__ import annotations

import ctypes
import sys
import threading
import time
from ctypes import POINTER, byref, c_ubyte, c_ulong, c_ulonglong, c_ushort, c_wchar_p, cast

sys.coinit_flags = 0  # COINIT_MULTITHREADED, so WPD event callbacks run on worker threads
import comtypes  # noqa: E402
import comtypes.client as cc  # noqa: E402
from comtypes import GUID, COMObject  # noqa: E402

from ..ptp import Event, Response  # noqa: E402
from .base import DataPhase, Transport  # noqa: E402

_api = cc.GetModule("PortableDeviceApi.dll")
_types = cc.GetModule("PortableDeviceTypes.dll")
_ole32 = ctypes.oledll.ole32
_ole32.CoTaskMemFree.restype = None
_ole32.CoTaskMemFree.argtypes = [ctypes.c_void_p]

_MTP_FMT = "{4D545058-1A2E-4106-A357-771E0819FC56}"
_COMMON_FMT = "{F0422A9C-5DC8-4440-B5BD-5DF28835658A}"
_CLIENT_FMT = "{204D9F0C-2292-4080-9F42-40664E70F859}"
_EVENT_FMT = "{15AB1953-F817-4FEF-A921-5676E838F6E0}"
_EVT_PARAMS_FMT = "{4D545058-EF88-4E4D-95C3-4F327F728A96}"
# Data1 of this GUID = (PTP event code << 16); low word observed as 0.
_VENDOR_EVENT_TAIL = "-5738-4FF2-8445-BE3126691059}"

VT_UI4 = 19


def _key(fmtid: str, pid: int):
    k = _types._tagpropertykey()
    k.fmtid = GUID(fmtid)
    k.pid = pid
    return ctypes.pointer(k)


# commands (pid within WPD_CATEGORY_MTP_EXT_VENDOR_OPERATIONS)
CMD_GET_SUPPORTED_VENDOR_OPCODES = 11
CMD_EXECUTE_NO_DATA = 12
CMD_EXECUTE_DATA_TO_READ = 13
CMD_EXECUTE_DATA_TO_WRITE = 14
CMD_READ_DATA = 15
CMD_WRITE_DATA = 16
CMD_END_DATA_TRANSFER = 17
CMD_GET_VENDOR_EXTENSION_DESCRIPTION = 18

K_CATEGORY = _key(_COMMON_FMT, 1001)
K_COMMAND_ID = _key(_COMMON_FMT, 1002)
K_HRESULT = _key(_COMMON_FMT, 1003)
K_OPCODE = _key(_MTP_FMT, 1001)
K_OP_PARAMS = _key(_MTP_FMT, 1002)
K_RESP_CODE = _key(_MTP_FMT, 1003)
K_RESP_PARAMS = _key(_MTP_FMT, 1004)
K_VENDOR_OPCODES = _key(_MTP_FMT, 1005)
K_CONTEXT = _key(_MTP_FMT, 1006)
K_TOTAL_SIZE = _key(_MTP_FMT, 1007)
K_TO_READ = _key(_MTP_FMT, 1008)
K_READ = _key(_MTP_FMT, 1009)
K_TO_WRITE = _key(_MTP_FMT, 1010)
K_WRITTEN = _key(_MTP_FMT, 1011)
K_DATA = _key(_MTP_FMT, 1012)
K_OPTIMAL_BUF = _key(_MTP_FMT, 1013)
K_VENDOR_DESC = _key(_MTP_FMT, 1014)
K_EVENT_PARAMS = _key(_EVT_PARAMS_FMT, 1011)
K_EVENT_ID = _key(_EVENT_FMT, 3)
K_CLIENT_NAME = _key(_CLIENT_FMT, 2)
K_CLIENT_MAJOR = _key(_CLIENT_FMT, 3)
K_CLIENT_MINOR = _key(_CLIENT_FMT, 4)
K_CLIENT_REVISION = _key(_CLIENT_FMT, 5)
K_CLIENT_ACCESS = _key(_CLIENT_FMT, 9)


class _PROPVARIANT(ctypes.Structure):
    """Minimal PROPVARIANT (24 bytes on x64); only VT_UI4 is used here."""
    class _U(ctypes.Union):
        _fields_ = [("ulVal", c_ulong), ("uhVal", c_ulonglong), ("pad", c_ubyte * 16)]
    _fields_ = [("vt", c_ushort), ("r1", c_ushort), ("r2", c_ushort), ("r3", c_ushort), ("u", _U)]


def _pv_ptr(pv: _PROPVARIANT):
    return cast(byref(pv), POINTER(_types.tag_inner_PROPVARIANT))


def _new_values():
    return comtypes.CoCreateInstance(_types.PortableDeviceValues._reg_clsid_,
                                     interface=_types.IPortableDeviceValues)


def _new_collection(values: list[int]):
    coll = comtypes.CoCreateInstance(_types.PortableDevicePropVariantCollection._reg_clsid_,
                                     interface=_types.IPortableDevicePropVariantCollection)
    for v in values:
        pv = _PROPVARIANT()
        pv.vt = VT_UI4
        pv.u.ulVal = v & 0xFFFFFFFF
        coll.Add(_pv_ptr(pv))
    return coll


def _collection_u32(unk) -> list[int]:
    coll = unk.QueryInterface(_types.IPortableDevicePropVariantCollection)
    n = c_ulong()
    coll._IPortableDevicePropVariantCollection__com_GetCount(byref(n))
    out = []
    for i in range(n.value):
        pv = _PROPVARIANT()
        coll._IPortableDevicePropVariantCollection__com_GetAt(i, _pv_ptr(pv))
        out.append(pv.u.ulVal)
        _ole32.PropVariantClear(byref(pv))
    return out


# Standard WPD event GUIDs that the MTP driver synthesizes from PTP events.
WPD_EVENT_NAMES = {
    "{A726DA95-E207-4B02-8D44-BEF2E86CBFFC}": "WPD_EVENT_OBJECT_ADDED",
    "{BE82AB88-A52C-4823-96E5-D0272671FC38}": "WPD_EVENT_OBJECT_REMOVED",
    "{1445A759-2E01-485D-9F27-FF07DAE697AB}": "WPD_EVENT_OBJECT_UPDATED",
    "{E4CBCA1B-6918-48B9-85EE-02BE7C850AF9}": "WPD_EVENT_DEVICE_REMOVED",
    "{7755CF53-C1ED-44F3-B5A2-451E2C376B27}": "WPD_EVENT_DEVICE_RESET",
    "{36885AA1-CD54-4DAA-B3D0-AFB3E03F5999}": "WPD_EVENT_DEVICE_CAPABILITIES_UPDATED",
    "{8D16A0A1-F2C6-41DA-8F19-5E53721ADBF2}": "WPD_EVENT_OBJECT_TRANSFER_REQUESTED",
}


class _Unicode:
    """Helpers for IPortableDeviceManager's (buffer, count) string getters."""

    @staticmethod
    def call(fn, pnp_id: str) -> str:
        n = c_ulong(0)
        try:
            fn(pnp_id, None, byref(n))
            buf = ctypes.create_unicode_buffer(n.value + 1)
            fn(pnp_id, cast(buf, POINTER(c_ushort)), byref(n))
            return buf.value
        except comtypes.COMError:
            return ""


def _manager():
    return comtypes.CoCreateInstance(_api.PortableDeviceManager._reg_clsid_,
                                     interface=_api.IPortableDeviceManager)


def list_devices() -> list[dict]:
    """Enumerate WPD devices: [{pnp_id, name, manufacturer, description}]."""
    mgr = _manager()
    n = c_ulong(0)
    mgr._IPortableDeviceManager__com_GetDevices(None, byref(n))
    if n.value == 0:
        return []
    arr = (c_wchar_p * n.value)()
    mgr._IPortableDeviceManager__com_GetDevices(cast(arr, POINTER(c_wchar_p)), byref(n))
    out = []
    for i in range(n.value):
        pid = arr[i]
        out.append({
            "pnp_id": pid,
            "name": _Unicode.call(mgr._IPortableDeviceManager__com_GetDeviceFriendlyName, pid),
            "manufacturer": _Unicode.call(mgr._IPortableDeviceManager__com_GetDeviceManufacturer, pid),
            "description": _Unicode.call(mgr._IPortableDeviceManager__com_GetDeviceDescription, pid),
        })
    return out


def find_lumix() -> dict | None:
    for d in list_devices():
        if "vid_04da" in d["pnp_id"].lower():
            return d
    return None


class _EventSink(COMObject):
    _com_interfaces_ = [_api.IPortableDeviceEventCallback]

    def __init__(self, transport: "WPDTransport"):
        super().__init__()
        self._t = transport

    def OnEvent(self, values):
        try:
            self._t._on_wpd_event(values)
        except Exception as e:  # never let an exception cross the COM boundary
            self._t.log_note(kind="event_error", error=repr(e))
        return 0


class WPDTransport(Transport):
    """PTP over the Windows MTP class driver."""

    READ_CHUNK = 8 * 1024 * 1024
    WRITE_CHUNK = 1024 * 1024

    def __init__(self, pnp_id: str, client_name: str = "lumix-usb-research"):
        super().__init__()
        self.pnp_id = pnp_id
        info = _new_values()
        info.SetStringValue(K_CLIENT_NAME, client_name)
        info.SetUnsignedIntegerValue(K_CLIENT_MAJOR, 0)
        info.SetUnsignedIntegerValue(K_CLIENT_MINOR, 1)
        info.SetUnsignedIntegerValue(K_CLIENT_REVISION, 0)
        info.SetUnsignedIntegerValue(K_CLIENT_ACCESS, 0xC0000000)  # GENERIC_READ|WRITE
        self.dev = comtypes.CoCreateInstance(_api.PortableDeviceFTM._reg_clsid_,
                                             interface=_api.IPortableDevice)
        self.dev.Open(pnp_id, info)
        self._sink = _EventSink(self)
        self._cookie = self.dev.Advise(0, self._sink, None)
        self.closed = False

    @classmethod
    def open_first(cls) -> "WPDTransport":
        d = find_lumix()
        if not d:
            raise RuntimeError("no Panasonic (VID 04DA) WPD device found")
        return cls(d["pnp_id"])

    # -- WPD plumbing -----------------------------------------------------
    def _send(self, command_id: int, setup) -> object:
        p = _new_values()
        p.SetGuidValue(K_CATEGORY, GUID(_MTP_FMT))
        p.SetUnsignedIntegerValue(K_COMMAND_ID, command_id)
        setup(p)
        res = self.dev.SendCommand(0, p).QueryInterface(_types.IPortableDeviceValues)
        hr = res.GetErrorValue(K_HRESULT)
        if hr != 0:
            raise OSError(f"WPD command {command_id} failed: HRESULT 0x{hr & 0xFFFFFFFF:08X}")
        return res

    @staticmethod
    def _response(opcode: int, res, data: bytes = b"") -> Response:
        code = res.GetUnsignedIntegerValue(K_RESP_CODE)
        try:
            params = _collection_u32(res.GetIUnknownValue(K_RESP_PARAMS))
        except comtypes.COMError:
            params = []
        return Response(opcode, code, params, data)

    def _op_setup(self, opcode: int, params: list[int], extra=None):
        def setup(p):
            p.SetUnsignedIntegerValue(K_OPCODE, opcode)
            p.SetIUnknownValue(K_OP_PARAMS, _new_collection(params))
            if extra:
                extra(p)
        return setup

    def _end(self, opcode: int, ctx: str, data: bytes = b"") -> Response:
        res = self._send(CMD_END_DATA_TRANSFER, lambda p: p.SetStringValue(K_CONTEXT, ctx))
        return self._response(opcode, res, data)

    def _execute(self, opcode, params, phase, out_data) -> Response:
        if phase == DataPhase.NONE:
            res = self._send(CMD_EXECUTE_NO_DATA, self._op_setup(opcode, params))
            return self._response(opcode, res)

        if phase == DataPhase.READ:
            res = self._send(CMD_EXECUTE_DATA_TO_READ, self._op_setup(opcode, params))
            ctx = res.GetStringValue(K_CONTEXT)
            total = res.GetUnsignedLargeIntegerValue(K_TOTAL_SIZE)
            buf = bytearray()
            while len(buf) < total:
                want = min(self.READ_CHUNK, total - len(buf))
                scratch = (c_ubyte * want)()

                def setup(p, want=want, scratch=scratch):
                    p.SetStringValue(K_CONTEXT, ctx)
                    p.SetUnsignedIntegerValue(K_TO_READ, want)
                    p.SetBufferValue(K_DATA, scratch, want)
                r = self._send(CMD_READ_DATA, setup)
                got = r.GetUnsignedIntegerValue(K_READ)
                ptr, size = r.GetBufferValue(K_DATA)
                buf += ctypes.string_at(ptr, min(got, size))
                _ole32.CoTaskMemFree(ptr)
                if got == 0:
                    break
            return self._end(opcode, ctx, bytes(buf))

        # WRITE
        def extra(p):
            p.SetUnsignedLargeIntegerValue(K_TOTAL_SIZE, len(out_data))
        res = self._send(CMD_EXECUTE_DATA_TO_WRITE, self._op_setup(opcode, params, extra))
        ctx = res.GetStringValue(K_CONTEXT)
        off = 0
        while off < len(out_data):
            chunk = out_data[off:off + self.WRITE_CHUNK]
            cbuf = (c_ubyte * len(chunk)).from_buffer_copy(chunk)

            def setup(p, chunk=chunk, cbuf=cbuf):
                p.SetStringValue(K_CONTEXT, ctx)
                p.SetUnsignedIntegerValue(K_TO_WRITE, len(chunk))
                p.SetBufferValue(K_DATA, cbuf, len(chunk))
            r = self._send(CMD_WRITE_DATA, setup)
            off += r.GetUnsignedIntegerValue(K_WRITTEN) or len(chunk)
        return self._end(opcode, ctx)

    def supported_vendor_opcodes(self) -> list[int]:
        res = self._send(CMD_GET_SUPPORTED_VENDOR_OPCODES, lambda p: None)
        return _collection_u32(res.GetIUnknownValue(K_VENDOR_OPCODES))

    def vendor_extension_description(self) -> str:
        res = self._send(CMD_GET_VENDOR_EXTENSION_DESCRIPTION, lambda p: None)
        return res.GetStringValue(K_VENDOR_DESC)

    # -- events -----------------------------------------------------------
    def _on_wpd_event(self, values) -> None:
        vals = values.QueryInterface(_types.IPortableDeviceValues)
        gid = str(vals.GetGuidValue(K_EVENT_ID)).upper()
        if gid.endswith(_VENDOR_EVENT_TAIL):
            code = int(gid[1:5], 16)  # Data1 = (event code << 16), verified on S5II
            try:
                params = _collection_u32(vals.GetIUnknownValue(K_EVENT_PARAMS))
            except comtypes.COMError:
                params = []
            ev = Event(code, params, time.time())
            self.events.put(ev)
            self.log_note(kind="event", code=f"0x{code:04X}", params=[f"0x{p:08X}" for p in params])
        else:
            name = WPD_EVENT_NAMES.get(gid, gid)
            self.log_note(kind="wpd_event", guid=gid, name=name)
            self.events.put(Event(-1, [], time.time()))  # marker: non-vendor WPD event
            self.wpd_events.append((time.time(), name))

    wpd_events: list = []

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        try:
            self.dev.Unadvise(self._cookie)
        except Exception:
            pass
        try:
            self.dev.Close()
        except Exception:
            pass
