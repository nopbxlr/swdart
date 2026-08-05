// WebUSB transport (browser). package:web doesn't include the WebUSB API, so we
// bind navigator.usb directly with dart:js_interop.
import 'dart:js_interop';
import 'dart:typed_data';

import 'transport.dart';
import 'util.dart';

@JS('navigator.usb')
external _USB get _usb;

@JS('navigator.usb')
external JSAny? get _usbRaw;

extension type _USB._(JSObject _) implements JSObject {
  external JSPromise<JSArray<_USBDevice>> getDevices();
  external JSPromise<_USBDevice> requestDevice(JSObject options);
}

extension type _USBDevice._(JSObject _) implements JSObject {
  external int get vendorId;
  external int get productId;
  external String? get productName;
  external _USBConfiguration? get configuration;
  external JSPromise<JSAny?> open();
  external JSPromise<JSAny?> close();
  external JSPromise<JSAny?> selectConfiguration(int configurationValue);
  external JSPromise<JSAny?> claimInterface(int interfaceNumber);
  external JSPromise<JSAny?> releaseInterface(int interfaceNumber);
  external JSPromise<_USBInTransferResult> transferIn(int endpointNumber, int length);
  external JSPromise<_USBOutTransferResult> transferOut(int endpointNumber, JSObject data);
}

extension type _USBConfiguration._(JSObject _) implements JSObject {
  external JSArray<_USBInterface> get interfaces;
}

extension type _USBInterface._(JSObject _) implements JSObject {
  external int get interfaceNumber;
  external _USBAlternateInterface get alternate;
}

extension type _USBAlternateInterface._(JSObject _) implements JSObject {
  external int get interfaceClass;
  external JSArray<_USBEndpoint> get endpoints;
}

extension type _USBEndpoint._(JSObject _) implements JSObject {
  external int get endpointNumber;
  external String get direction; // 'in' | 'out'
  external String get type; // 'bulk' | ...
}

extension type _USBInTransferResult._(JSObject _) implements JSObject {
  external _JsDataView? get data;
  external String get status;
}

extension type _USBOutTransferResult._(JSObject _) implements JSObject {
  external String get status;
}

extension type _JsDataView._(JSObject _) implements JSObject {
  external JSArrayBuffer get buffer;
  external int get byteOffset;
  external int get byteLength;
}

bool get isUsbSupported => _usbRaw != null;

class _WebUsbTransport implements UsbTransport {
  _WebUsbTransport(this._device, this._ifaceNum, this._epOut, this._epIn);
  final _USBDevice _device;
  final int _ifaceNum;
  final int _epOut;
  final int _epIn;

  @override
  int get productId => _device.productId;

  @override
  String get productName {
    final n = _device.productName;
    return (n != null && n.isNotEmpty) ? n : 'ST-Link';
  }

  @override
  bool get isV3 => v3Pids.contains(productId);

  @override
  Future<Uint8List> xfer(List<int> command, {int rxLen = 0, Uint8List? data}) async {
    final packet = Uint8List(16);
    packet.setRange(0, command.length, command);
    final out = await _device.transferOut(_epOut, packet.toJS).toDart;
    if (out.status != 'ok') throw SwdException('USB command transfer failed: ${out.status}');

    if (data != null && data.isNotEmpty) {
      // Copy to a fresh, contiguous, offset-0 array: `data` is often a
      // sublistView, and passing a typed-data view straight to transferOut can
      // send the wrong bytes (the view's offset/length may be dropped).
      final clean = Uint8List.fromList(data);
      final dOut = await _device.transferOut(_epOut, clean.toJS).toDart;
      if (dOut.status != 'ok') throw SwdException('USB data transfer failed: ${dOut.status}');
    }

    if (rxLen > 0) {
      final rx = await _device.transferIn(_epIn, rxLen).toDart;
      if (rx.status != 'ok' || rx.data == null) throw SwdException('USB read failed: ${rx.status}');
      final dv = rx.data!;
      return Uint8List.fromList(dv.buffer.toDart.asUint8List(dv.byteOffset, dv.byteLength));
    }
    return Uint8List(0);
  }

  @override
  Future<void> close() async {
    try {
      await _device.releaseInterface(_ifaceNum).toDart;
    } catch (_) {}
    try {
      await _device.close().toDart;
    } catch (_) {}
  }
}

Future<UsbTransport> _openDevice(_USBDevice device) async {
  await device.open().toDart;
  if (device.configuration == null) {
    await device.selectConfiguration(1).toDart;
  }
  final cfg = device.configuration;
  if (cfg == null) throw SwdException('USB device has no active configuration');

  for (final iface in cfg.interfaces.toDart) {
    final alt = iface.alternate;
    if (alt.interfaceClass != 0xff) continue;
    var epOut = -1;
    var epIn = -1;
    for (final ep in alt.endpoints.toDart) {
      if (ep.type != 'bulk') continue;
      if (ep.direction == 'out' && epOut < 0) epOut = ep.endpointNumber;
      if (ep.direction == 'in' && epIn < 0) epIn = ep.endpointNumber;
    }
    if (epOut >= 0 && epIn >= 0) {
      await device.claimInterface(iface.interfaceNumber).toDart;
      return _WebUsbTransport(device, iface.interfaceNumber, epOut, epIn);
    }
  }
  await device.close().toDart;
  throw SwdException(
    'No ST-Link debug interface found. On Windows, bind the ST-Link to WinUSB '
    '(official ST driver or Zadig).',
  );
}

Future<UsbTransport?> reacquireStlink() async {
  if (!isUsbSupported) return null;
  final granted = (await _usb.getDevices().toDart).toDart;
  for (final d in granted) {
    if (d.vendorId == stlinkVid) return _openDevice(d);
  }
  return null;
}

Future<UsbTransport> requestStlink() async {
  final options = <String, dynamic>{
    'filters': <dynamic>[
      <String, dynamic>{'vendorId': stlinkVid},
    ],
  }.jsify()! as JSObject;
  final device = await _usb.requestDevice(options).toDart;
  return _openDevice(device);
}
