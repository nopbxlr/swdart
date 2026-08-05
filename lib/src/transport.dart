// USB transport abstraction for ST-Link probes. Two implementations:
//   - WebUSB (transport_web.dart) via navigator.usb (dart:js_interop)
//   - native libusb-1.0 (transport_native.dart) via direct dart:ffi
// The ST-Link wire protocol is a 16-byte command packet on a bulk OUT endpoint,
// an optional data phase, then an optional bulk IN response.
import 'dart:typed_data';

const stlinkVid = 0x0483;

/// STLINK-V3 product IDs (same APIv2 command set we use).
const v3Pids = <int>{0x374d, 0x374e, 0x374f, 0x3753, 0x3754, 0x3755, 0x3757};

abstract class UsbTransport {
  int get productId;
  String get productName;
  bool get isV3 => v3Pids.contains(productId);

  /// Send a 16-byte command, optionally a data phase, then read [rxLen] bytes.
  Future<Uint8List> xfer(List<int> command, {int rxLen = 0, Uint8List? data});

  Future<void> close();
}
