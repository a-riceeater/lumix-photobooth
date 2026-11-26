"""Offline tests against payloads captured from the DC-S5M2 (fw 3.6)."""
import pathlib
import struct

from lumix_usb.panasonic import LiveviewSetting, parse_liveview, parse_tlv, tlv_value
from lumix_usb.ptp import DeviceInfo, ObjectInfo, Reader, ptp_string

SAMPLES = pathlib.Path(__file__).resolve().parents[1] / "samples"


def test_deviceinfo():
    di = DeviceInfo.parse((SAMPLES / "deviceinfo_wpd.bin").read_bytes())
    assert di.vendor_extension_id == 0x1C
    assert di.model == "DC-S5M2" and di.manufacturer == "Panasonic"
    assert {0x9102, 0x9103, 0x9104} <= set(di.operations)
    assert {0xC101, 0xC102, 0xC108, 0xC109} <= set(di.events)


def test_liveview_frames():
    for i in (1, 2, 3):
        raw = (SAMPLES / f"liveview_raw_{i}.bin").read_bytes()
        f = parse_liveview(raw)
        assert f.jpeg[:2] == b"\xff\xd8" and f.jpeg[-2:] == b"\xff\xd9"
        assert len(raw) - len(f.jpeg) == 244
        assert set(range(0x17000000, 0x17000006)) <= set(f.tags)
        assert len(f.histogram) == 64
        # 0x17000002 reports JPEG length + 12 (observed on all samples)
        assert struct.unpack_from("<I", f.tags[0x17000002], 4)[0] == len(f.jpeg) + 12


def test_tlv_iso_group():
    # 0x9402(0x02000020) reply captured from the S5II
    data = bytes.fromhex("2100000204000000ffffffff220000020400000000c80000"
                         "2500000202000000ffff")
    tl = parse_tlv(data)
    assert tlv_value(tl[0x02000021]) == 0xFFFFFFFF
    assert tlv_value(tl[0x02000022]) == 51200
    assert tlv_value(tl[0x02000025]) == 0xFFFF


def test_liveview_setting_roundtrip():
    s = LiveviewSetting(480, 640, 32, 30)
    b = s.pack()
    assert b == bytes.fromhex("1100800d08000000e00180022000" "1e00")


def test_objectinfo_sdram():
    # header of the ObjectInfo returned for SD handle 0x52268985 (truncated in log)
    blob = bytearray(struct.pack("<IHHIHIIIIIIIHII", 0x00020001, 0x3801, 0, 9922048, 0x3808,
                                 0, 0, 0, 6000, 4000, 0, 0, 0, 0, 0))
    blob += ptp_string("P1542437.JPG") + ptp_string("20261125T203732") + ptp_string("") + ptp_string("")
    oi = ObjectInfo.parse(bytes(blob))
    assert oi.filename == "P1542437.JPG" and oi.width == 6000 and oi.format_name == "EXIF/JPEG"


def test_ptp_string_roundtrip():
    assert Reader(ptp_string("DC-S5M2")).string() == "DC-S5M2"
