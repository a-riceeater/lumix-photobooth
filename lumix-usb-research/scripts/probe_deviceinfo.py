"""Read-only probe: WPD vendor-extension info and PTP GetDeviceInfo (0x1001)."""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "src"))
from lumix_usb.transport.wpd import WPDTransport
from lumix_usb.ptp import DeviceInfo, rc_name

out = sys.argv[1] if len(sys.argv) > 1 else "samples/deviceinfo_wpd.bin"
t = WPDTransport.open_first()
try:
    print("vendor ext desc:", repr(t.vendor_extension_description()))
    print("supported vendor opcodes:", [hex(x) for x in t.supported_vendor_opcodes()])
    r = t.read(0x1001)
    print(rc_name(r.code), len(r.data))
    open(out, "wb").write(r.data)
    di = DeviceInfo.parse(r.data)
    print(hex(di.vendor_extension_id), di.vendor_extension_version, repr(di.vendor_extension_desc))
    print(di.manufacturer, di.model, di.device_version, di.serial_number)
    print("ops", [hex(x) for x in di.operations])
    print("events", [hex(x) for x in di.events])
    print("props", [hex(x) for x in di.device_props])
    print("capfmt", [hex(x) for x in di.capture_formats], "imgfmt", [hex(x) for x in di.image_formats])
finally:
    t.close()
