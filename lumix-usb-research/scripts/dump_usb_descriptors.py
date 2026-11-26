"""Read-only: print cached USB descriptors (libusb via hub IOCTLs; does not claim the device)."""
import usb.core, libusb_package
d = usb.core.find(idVendor=0x04DA, idProduct=0x2382, backend=libusb_package.get_libusb1_backend())
if d is None:
    raise SystemExit("camera not found")
print(d)
print("speed", d.speed, {1: "low", 2: "full", 3: "high (USB 2.0, 480 Mb/s)", 4: "super (5 Gb/s)", 5: "super+ (10 Gb/s)"}.get(d.speed))
