"""Platform-neutral PTP (ISO 15740) codec: constants and dataset parsers.

Nothing in this module touches a transport. Everything is little-endian, as
mandated by PTP over USB. This file is intended to be ported 1:1 to Swift.
"""
from __future__ import annotations

import struct
from dataclasses import dataclass, field


class OC:
    """Standard PTP/MTP operation codes used by this project."""
    GetDeviceInfo = 0x1001
    OpenSession = 0x1002
    CloseSession = 0x1003
    GetStorageIDs = 0x1004
    GetStorageInfo = 0x1005
    GetNumObjects = 0x1006
    GetObjectHandles = 0x1007
    GetObjectInfo = 0x1008
    GetObject = 0x1009
    GetThumb = 0x100A
    DeleteObject = 0x100B  # never used by this project
    GetDevicePropDesc = 0x1014
    GetDevicePropValue = 0x1015
    SetDevicePropValue = 0x1016
    GetPartialObject = 0x101B
    MTP_GetObjectPropsSupported = 0x9801
    MTP_GetObjectPropValue = 0x9803


RC_NAMES = {
    0x2001: "OK", 0x2002: "GeneralError", 0x2003: "SessionNotOpen",
    0x2004: "InvalidTransactionID", 0x2005: "OperationNotSupported",
    0x2006: "ParameterNotSupported", 0x2007: "IncompleteTransfer",
    0x2008: "InvalidStorageID", 0x2009: "InvalidObjectHandle",
    0x200A: "DevicePropNotSupported", 0x200B: "InvalidObjectFormatCode",
    0x200C: "StoreFull", 0x200D: "ObjectWriteProtected", 0x200E: "StoreReadOnly",
    0x200F: "AccessDenied", 0x2010: "NoThumbnailPresent", 0x2011: "SelfTestFailed",
    0x2012: "PartialDeletion", 0x2013: "StoreNotAvailable",
    0x2014: "SpecificationByFormatUnsupported", 0x2015: "NoValidObjectInfo",
    0x2016: "InvalidCodeFormat", 0x2017: "UnknownVendorCode",
    0x2018: "CaptureAlreadyTerminated", 0x2019: "DeviceBusy",
    0x201A: "InvalidParentObject", 0x201B: "InvalidDevicePropFormat",
    0x201C: "InvalidDevicePropValue", 0x201D: "InvalidParameter",
    0x201E: "SessionAlreadyOpen", 0x201F: "TransactionCancelled",
    0x2020: "SpecificationOfDestinationUnsupported",
}


class RC:
    OK = 0x2001
    GeneralError = 0x2002
    SessionNotOpen = 0x2003
    OperationNotSupported = 0x2005
    ParameterNotSupported = 0x2006
    InvalidObjectHandle = 0x2009
    DeviceBusy = 0x2019
    InvalidDevicePropValue = 0x201C
    InvalidParameter = 0x201D
    SessionAlreadyOpen = 0x201E


EC_NAMES = {
    0x4002: "ObjectAdded", 0x4003: "ObjectRemoved", 0x4004: "StoreAdded",
    0x4005: "StoreRemoved", 0x4006: "DevicePropChanged", 0x4007: "ObjectInfoChanged",
    0x4008: "DeviceInfoChanged", 0x400A: "StoreFull", 0x400C: "StorageInfoChanged",
    0x400D: "CaptureComplete",
}

OFC_NAMES = {
    0x3000: "Undefined", 0x3001: "Association", 0x3801: "EXIF/JPEG",
    0x3800: "UndefinedImage(RW2)", 0x300D: "MOV", 0xB982: "MP4",
}


def rc_name(code: int) -> str:
    return RC_NAMES.get(code, f"0x{code:04X}")


class PTPError(Exception):
    def __init__(self, opcode: int, code: int, msg: str = ""):
        self.opcode, self.code = opcode, code
        super().__init__(f"op 0x{opcode:04X} -> {rc_name(code)} (0x{code:04X}) {msg}".strip())


@dataclass
class Response:
    """Result of one PTP transaction, independent of transport."""
    opcode: int
    code: int
    params: list[int] = field(default_factory=list)
    data: bytes = b""

    @property
    def ok(self) -> bool:
        return self.code == RC.OK

    def check(self) -> "Response":
        if not self.ok:
            raise PTPError(self.opcode, self.code)
        return self


@dataclass
class Event:
    code: int
    params: list[int] = field(default_factory=list)
    timestamp: float = 0.0

    def __str__(self) -> str:
        name = EC_NAMES.get(self.code, "")
        ps = " ".join(f"0x{p:08X}" for p in self.params)
        return f"event 0x{self.code:04X}{' ' + name if name else ''} [{ps}]"


class Reader:
    """Sequential little-endian reader for PTP datasets."""

    def __init__(self, data: bytes, offset: int = 0):
        self.data, self.pos = data, offset

    def _take(self, fmt: str):
        size = struct.calcsize(fmt)
        if self.pos + size > len(self.data):
            raise ValueError(f"dataset truncated at {self.pos} (+{size} > {len(self.data)})")
        (v,) = struct.unpack_from(fmt, self.data, self.pos)
        self.pos += size
        return v

    def u8(self) -> int: return self._take("<B")
    def u16(self) -> int: return self._take("<H")
    def u32(self) -> int: return self._take("<I")
    def u64(self) -> int: return self._take("<Q")

    def string(self) -> str:
        """PTP string: u8 char count (incl. NUL), then UTF-16LE code units."""
        n = self.u8()
        if n == 0:
            return ""
        raw = self.data[self.pos:self.pos + 2 * n]
        self.pos += 2 * n
        return raw.decode("utf-16-le", errors="replace").rstrip("\x00")

    def array16(self) -> list[int]:
        return [self.u16() for _ in range(self.u32())]

    def array32(self) -> list[int]:
        return [self.u32() for _ in range(self.u32())]


def ptp_string(s: str) -> bytes:
    if not s:
        return b"\x00"
    enc = (s + "\x00").encode("utf-16-le")
    return bytes([len(enc) // 2]) + enc


@dataclass
class DeviceInfo:
    standard_version: int
    vendor_extension_id: int
    vendor_extension_version: int
    vendor_extension_desc: str
    functional_mode: int
    operations: list[int]
    events: list[int]
    device_props: list[int]
    capture_formats: list[int]
    image_formats: list[int]
    manufacturer: str
    model: str
    device_version: str
    serial_number: str

    @classmethod
    def parse(cls, data: bytes) -> "DeviceInfo":
        r = Reader(data)
        return cls(r.u16(), r.u32(), r.u16(), r.string(), r.u16(), r.array16(),
                   r.array16(), r.array16(), r.array16(), r.array16(),
                   r.string(), r.string(), r.string(), r.string())


@dataclass
class StorageInfo:
    storage_type: int
    filesystem_type: int
    access: int
    max_capacity: int
    free_bytes: int
    free_images: int
    description: str
    volume_label: str

    @classmethod
    def parse(cls, data: bytes) -> "StorageInfo":
        r = Reader(data)
        return cls(r.u16(), r.u16(), r.u16(), r.u64(), r.u64(), r.u32(), r.string(), r.string())


@dataclass
class ObjectInfo:
    storage_id: int
    format: int
    protection: int
    compressed_size: int
    thumb_format: int
    thumb_size: int
    thumb_width: int
    thumb_height: int
    width: int
    height: int
    bit_depth: int
    parent: int
    association_type: int
    association_desc: int
    sequence_number: int
    filename: str
    capture_date: str
    modification_date: str
    keywords: str

    @classmethod
    def parse(cls, data: bytes) -> "ObjectInfo":
        r = Reader(data)
        return cls(r.u32(), r.u16(), r.u16(), r.u32(), r.u16(), r.u32(), r.u32(), r.u32(),
                   r.u32(), r.u32(), r.u32(), r.u32(), r.u16(), r.u32(), r.u32(),
                   r.string(), r.string(), r.string(), r.string())

    @classmethod
    def parse_panasonic(cls, data: bytes) -> "ObjectInfo":
        """Panasonic 0x9110 GetObjectInfo (seen in LUMIX Tether 2.12 traffic, verified on
        S5II): u32 header (0x00010001), then ObjectInfo with a u64 CompressedSize."""
        r = Reader(data, 4)
        storage, fmt, prot, size = r.u32(), r.u16(), r.u16(), r.u64()
        return cls(storage, fmt, prot, size, r.u16(), r.u32(), r.u32(), r.u32(),
                   r.u32(), r.u32(), r.u32(), r.u32(), r.u16(), r.u32(), r.u32(),
                   r.string(), r.string(), r.string(), r.string())

    @property
    def format_name(self) -> str:
        return OFC_NAMES.get(self.format, f"0x{self.format:04X}")


def hexdump(data: bytes, limit: int = 256) -> str:
    out = []
    for i in range(0, min(len(data), limit), 16):
        chunk = data[i:i + 16]
        hx = " ".join(f"{b:02x}" for b in chunk)
        asc = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        out.append(f"{i:08x}  {hx:<47}  {asc}")
    if len(data) > limit:
        out.append(f"... ({len(data)} bytes total)")
    return "\n".join(out)
