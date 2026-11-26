# USB transport

## Device identification (VERIFIED)

| Field | Value |
|---|---|
| VID / PID | `0x04DA` (Panasonic) / `0x2382` (shared by GH5, G9, S-series in PC(Tether)/PTP mode) |
| bcdUSB / bcdDevice | 2.10 / 1.00 |
| Device class | 0 (per interface) |
| Configurations | 2: #1 bus-powered 500 mA, #2 self-powered 0 mA (identical interfaces) |
| Interface 0 | class 0x06 Still Image, subclass 0x01, protocol 0x01 (**PTP**) |
| Endpoints | `0x01` bulk OUT 512 B, `0x81` bulk IN 512 B, `0x82` interrupt IN 64 B (bInterval 8) |
| Other interfaces | **None.** No vendor interface, no mass storage, no UVC in PC(Tether). |
| Strings | Manufacturer "Panasonic", product "DC-S5M2", serial `000000000000000000XJL2401160133` (via WPD) |
| Windows driver | Microsoft `wpdmtp.inf` / WUDFWpdMtp ("MTP USB Device"), class WPD |
| PTP DeviceInfo | VendorExtensionID `0x0000001C` (Panasonic), StandardVersion 100 |

Dump: `captures/usb_descriptors_s5m2_usb2.txt` (`scripts/dump_usb_descriptors.py`,
libgphoto-style read via libusb hub IOCTLs; it does **not** claim the device).

### Link speed
The camera enumerated at **High-Speed (USB 2.0, 480 Mb/s)** on this PC
(512-byte bulk packets). The S5II port is USB 3.2 capable; a SuperSpeed link would
report bcdUSB 3.x and 1024-byte packets. The measured ~34 MB/s object download is
near the practical USB 2.0 bulk ceiling, so a USB 3 cable/port should be tested
before drawing conclusions about transfer speed. Many USB-C cables are USB 2.0 only.

## Protocol layering

Panasonic uses **plain PTP over USB (ISO 15740 / USB Still Image class)** on the
standard three endpoints. Everything vendor-specific is expressed as ordinary PTP
operations in the 0x9xxx range, events in 0xCxxx, and opaque data phases:

* no extra USB interfaces, no vendor control transfers (beyond class requests the
  OS driver issues itself), no custom endpoints, no authentication handshake was
  needed for any verified operation;
* vendor opcodes are mostly **not advertised** in DeviceInfo (only 0x9102–0x9104
  are), but the camera executes them regardless.

Pending confirmation in LUMIX Tether traffic (USBPcap): that Tether uses nothing
outside this either.

## Transports evaluated on Windows

| Option | Driver change? | Vendor ops? | Events? | Verdict |
|---|---|---|---|---|
| **WPD MTP vendor-extension commands** (`IPortableDevice::SendCommand` with `WPD_COMMAND_MTP_EXT_*`) | **No** | **Yes, any opcode** | Yes, via `Advise` | **Chosen.** Works side-by-side with normal Windows use. |
| libusb / PyUSB with WinUSB | Yes (Zadig would replace wpdmtp) | Yes | Yes (interrupt EP) | Rejected: breaks Explorer/Tether access, needs approval. |
| libusbK/usbdk filter | Install filter driver | Yes | Yes | Not needed. |
| libgphoto2 on Windows | Needs libusb driver | Yes | Yes | Same driver problem. |
| WIA | No | No raw ops | – | Insufficient. |

### WPD vendor-extension mechanics (`src/lumix_usb/transport/wpd.py`)

Category `WPD_CATEGORY_MTP_EXT_VENDOR_OPERATIONS` = `{4D545058-1A2E-4106-A357-771E0819FC56}`
(constants copied from Windows SDK `WpdMtpExtensions.h`).

| Phase | Commands |
|---|---|
| none | `EXECUTE_COMMAND_WITHOUT_DATA_PHASE` (pid 12): in OPERATION_CODE, OPERATION_PARAMS(collection of VT_UI4) → out RESPONSE_CODE, RESPONSE_PARAMS |
| in | `EXECUTE_COMMAND_WITH_DATA_TO_READ` (13) → TRANSFER_CONTEXT, TRANSFER_TOTAL_DATA_SIZE; loop `READ_DATA` (15) with context, NUM_BYTES_TO_READ and a caller buffer in TRANSFER_DATA → data, NUM_BYTES_READ; `END_DATA_TRANSFER` (17) → RESPONSE_CODE/PARAMS |
| out | `EXECUTE_COMMAND_WITH_DATA_TO_WRITE` (14) with TRANSFER_TOTAL_DATA_SIZE → context; `WRITE_DATA` (16); `END_DATA_TRANSFER` |

Observed details:

* The driver opens the PTP session (0x1002) and assigns transaction IDs.
* `GET_SUPPORTED_VENDOR_OPCODES` returns only `0x9102, 0x9103, 0x9104` (from
  DeviceInfo), yet unlisted opcodes (0x9402, 0x9412, 0x9706, …) are forwarded.
* Vendor events arrive as GUID `{CCCC0000-5738-4FF2-8445-BE3126691059}` where
  `CCCC` is the PTP event code (**code << 16 in Data1**, verified), params in
  `WPD_PROPERTY_MTP_EXT_EVENT_PARAMS`.
* Read chunks of 8 MiB work (a 35.7 MB RW2 in 1.06 s).
* Per-transaction overhead ≈1–2 ms for small commands, ~8–15 ms for data reads.
* Data-in with zero bytes: `TOTAL_DATA_SIZE` = 0 → skip READ_DATA, still call END.
* comtypes pitfalls: the Api and Types typelibs each define `IPortableDeviceValues`
  and `PROPERTYKEY`; QueryInterface every result to the Types-lib interface and
  build keys from the Types-lib struct.

### Concurrency
Each PTP transaction must complete before the next starts. `Transport.execute`
holds a lock; liveview polling in one thread and capture in another interleave at
transaction granularity (verified, see live-view.md). Event callbacks arrive on a
WPD worker thread; the event pump never issues commands from inside the COM
callback (the ack is sent from a separate Python thread).

### Coexistence
WPD allows multiple clients to open the device (share mode), but this was not
exercised with Explorer/Tether at the same time (UNTESTED). Running
LUMIX Tether concurrently is **not** supported (two initiators interleaving
vendor ops on one session); close one before using the other.
