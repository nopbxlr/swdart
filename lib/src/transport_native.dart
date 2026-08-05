// Native USB transport (Windows/macOS/Linux) via direct libusb-1.0 FFI.
//
// Uses `libusb_open_device_with_vid_pid` so there is no config-descriptor
// struct marshalling — only scalar/pointer calls. Interface 0, IN endpoint
// 0x81; OUT endpoint per probe generation (see `_outEndpoint`). Requires
// libusb-1.0 present at runtime and, on Windows, the ST-Link bound to WinUSB
// (official ST driver or Zadig).
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'transport.dart';
import 'util.dart';

// Known ST-Link product IDs we try to open, in order (APIv2 — V2 and newer).
const _stlinkPids = <int>[
  0x3748, // V2
  0x374b, 0x3752, // V2-1
  0x374d, 0x374e, 0x374f, 0x3753, 0x3754, 0x3755, 0x3757, // V3
];

// PIDs whose bulk-OUT endpoint is 0x01 (ST-Link/V2-1 and V3).
const _outEp01Pids = <int>{
  0x374b, 0x3752, // V2-1
  0x374d, 0x374e, 0x374f, 0x3753, 0x3754, 0x3755, 0x3757, // V3
};

const _epIn = 0x81;
const _iface = 0;
const _timeout = 2000;

/// Bulk OUT endpoint address (OpenOCD stlink_usb.c): V2-1 and V3 use 0x01;
/// V1, V2, and any unrecognized clone default to 0x02. IN is 0x81 for all.
int _outEndpoint(int pid) => _outEp01Pids.contains(pid) ? 0x01 : 0x02;

// ── libusb signatures ────────────────────────────────────────────────
typedef _InitNative = Int32 Function(Pointer<Pointer<Void>>);
typedef _InitDart = int Function(Pointer<Pointer<Void>>);
typedef _ExitNative = Void Function(Pointer<Void>);
typedef _ExitDart = void Function(Pointer<Void>);
typedef _OpenVidPidNative = Pointer<Void> Function(Pointer<Void>, Uint16, Uint16);
typedef _OpenVidPidDart = Pointer<Void> Function(Pointer<Void>, int, int);
typedef _CloseNative = Void Function(Pointer<Void>);
typedef _CloseDart = void Function(Pointer<Void>);
typedef _ClaimNative = Int32 Function(Pointer<Void>, Int32);
typedef _ClaimDart = int Function(Pointer<Void>, int);
typedef _AutoDetachNative = Int32 Function(Pointer<Void>, Int32);
typedef _AutoDetachDart = int Function(Pointer<Void>, int);
typedef _BulkNative =
    Int32 Function(Pointer<Void>, Uint8, Pointer<Uint8>, Int32, Pointer<Int32>, Uint32);
typedef _BulkDart =
    int Function(Pointer<Void>, int, Pointer<Uint8>, int, Pointer<Int32>, int);

class _Libusb {
  _Libusb(DynamicLibrary lib)
      : init = lib.lookupFunction<_InitNative, _InitDart>('libusb_init'),
        exit = lib.lookupFunction<_ExitNative, _ExitDart>('libusb_exit'),
        openVidPid = lib.lookupFunction<_OpenVidPidNative, _OpenVidPidDart>(
            'libusb_open_device_with_vid_pid'),
        closeHandle = lib.lookupFunction<_CloseNative, _CloseDart>('libusb_close'),
        claim = lib.lookupFunction<_ClaimNative, _ClaimDart>('libusb_claim_interface'),
        release = lib.lookupFunction<_ClaimNative, _ClaimDart>('libusb_release_interface'),
        autoDetach = lib.lookupFunction<_AutoDetachNative, _AutoDetachDart>(
            'libusb_set_auto_detach_kernel_driver'),
        bulk = lib.lookupFunction<_BulkNative, _BulkDart>('libusb_bulk_transfer');

  final _InitDart init;
  final _ExitDart exit;
  final _OpenVidPidDart openVidPid;
  final _CloseDart closeHandle;
  final _ClaimDart claim;
  final _ClaimDart release;
  final _AutoDetachDart autoDetach;
  final _BulkDart bulk;

  static _Libusb open() {
    // Order: bare name (finds a lib bundled next to the app — Windows DLL search
    // and Linux $ORIGIN/lib RPATH cover that — or one on the system), then the
    // app's own directory explicitly, then common install locations. Works the
    // same in `flutter run` (debug) and a packaged release, since both place the
    // bundled lib beside the executable.
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[];
    if (Platform.isWindows) {
      candidates.addAll(['libusb-1.0.dll', '$exeDir\\libusb-1.0.dll']);
    } else if (Platform.isMacOS) {
      candidates.addAll([
        'libusb-1.0.0.dylib',
        'libusb-1.0.dylib',
        '$exeDir/../Frameworks/libusb-1.0.0.dylib',
        '$exeDir/../Frameworks/libusb-1.0.dylib',
        '/opt/homebrew/lib/libusb-1.0.0.dylib', // Apple Silicon Homebrew
        '/usr/local/lib/libusb-1.0.0.dylib', // Intel Homebrew
      ]);
    } else {
      candidates.addAll([
        'libusb-1.0.so.0',
        'libusb-1.0.so',
        '$exeDir/lib/libusb-1.0.so.0',
        '$exeDir/lib/libusb-1.0.so',
        '/usr/lib/x86_64-linux-gnu/libusb-1.0.so.0',
        '/lib/x86_64-linux-gnu/libusb-1.0.so.0',
      ]);
    }
    for (final name in candidates) {
      try {
        return _Libusb(DynamicLibrary.open(name));
      } catch (_) {}
    }
    throw SwdException(
      'libusb-1.0 could not be loaded. Place the binary beside the app '
      '(Windows: windows/libusb-1.0.dll; Linux: linux/libusb-1.0.so.0) so it is '
      'bundled, or install it system-wide (Linux: libusb-1.0-0; macOS: brew install libusb). '
      'See NATIVE.md.',
    );
  }
}

class _NativeUsbTransport implements UsbTransport {
  _NativeUsbTransport(this._lib, this._ctx, this._handle, this._pid);
  final _Libusb _lib;
  final Pointer<Void> _ctx;
  final Pointer<Void> _handle;
  final int _pid;

  @override
  int get productId => _pid;

  @override
  String get productName => isV3 ? 'STLINK-V3' : (_pid == 0x3748 ? 'ST-Link/V2' : 'ST-Link/V2-1');

  @override
  bool get isV3 => v3Pids.contains(_pid);

  Future<Uint8List> _bulkOut(int endpoint, Uint8List data) async {
    final buf = malloc<Uint8>(data.length);
    final transferred = malloc<Int32>();
    try {
      buf.asTypedList(data.length).setAll(0, data);
      final rc = _lib.bulk(_handle, endpoint, buf, data.length, transferred, _timeout);
      if (rc != 0) throw SwdException('libusb bulk OUT failed: $rc');
      return Uint8List(0);
    } finally {
      malloc.free(buf);
      malloc.free(transferred);
    }
  }

  Future<Uint8List> _bulkIn(int endpoint, int length) async {
    final buf = malloc<Uint8>(length);
    final transferred = malloc<Int32>();
    try {
      final rc = _lib.bulk(_handle, endpoint, buf, length, transferred, _timeout);
      if (rc != 0) throw SwdException('libusb bulk IN failed: $rc');
      final n = transferred.value;
      return Uint8List.fromList(buf.asTypedList(n));
    } finally {
      malloc.free(buf);
      malloc.free(transferred);
    }
  }

  int get _epOut => _outEndpoint(_pid);

  @override
  Future<Uint8List> xfer(List<int> command, {int rxLen = 0, Uint8List? data}) async {
    final packet = Uint8List(16);
    packet.setRange(0, command.length, command);
    await _bulkOut(_epOut, packet);
    if (data != null && data.isNotEmpty) await _bulkOut(_epOut, data);
    if (rxLen > 0) return _bulkIn(_epIn, rxLen);
    return Uint8List(0);
  }

  @override
  Future<void> close() async {
    try {
      _lib.release(_handle, _iface);
    } catch (_) {}
    _lib.closeHandle(_handle);
    _lib.exit(_ctx);
  }
}

Future<UsbTransport?> _open() async {
  final lib = _Libusb.open();
  final ctxPtr = malloc<Pointer<Void>>();
  try {
    if (lib.init(ctxPtr) != 0) throw SwdException('libusb_init failed');
    final ctx = ctxPtr.value;

    for (final pid in _stlinkPids) {
      final handle = lib.openVidPid(ctx, stlinkVid, pid);
      if (handle != nullptr) {
        try {
          lib.autoDetach(handle, 1); // Linux: detach any kernel driver
        } catch (_) {}
        final rc = lib.claim(handle, _iface);
        if (rc != 0) {
          lib.closeHandle(handle);
          lib.exit(ctx);
          throw SwdException('libusb_claim_interface failed: $rc (WinUSB driver bound?)');
        }
        return _NativeUsbTransport(lib, ctx, handle, pid);
      }
    }
    lib.exit(ctx);
    return null;
  } finally {
    malloc.free(ctxPtr);
  }
}

/// Native has no permission prompt; both entry points enumerate + open.
Future<UsbTransport?> reacquireStlink() => _open();

Future<UsbTransport> requestStlink() async {
  final t = await _open();
  if (t == null) throw SwdException('No ST-Link found on USB');
  return t;
}
