// ST-Link APIv2 debug protocol (ported from openocd-ts src/stlink/stlink.ts).
// Original TypeScript implementation of the publicly documented ST-Link wire
// protocol; this is a faithful Dart port.
import 'dart:typed_data';

import 'transport.dart';
import 'util.dart';

// Top-level commands
const _cmdGetVersion = 0xf1;
const _cmdDebug = 0xf2;
const _cmdDfu = 0xf3;
const _cmdGetCurrentMode = 0xf5;
const _cmdGetTargetVoltage = 0xf7;
const _cmdGetVersionV3 = 0xfb;

const _dfuExit = 0x07;

// CMD_DEBUG sub-commands (APIv2)
const _debugReadmem32 = 0x07;
const _debugWritemem32 = 0x08;
const _debugReadmem8 = 0x0c;
const _debugWritemem8 = 0x0d;
const _debugExit = 0x21;
const _apiv2Enter = 0x30;
const _apiv2ReadIdcodes = 0x31;
const _apiv2Resetsys = 0x32;
const _apiv2Readreg = 0x33;
const _apiv2Writereg = 0x34;
const _apiv2Writedebugreg = 0x35;
const _apiv2Readdebugreg = 0x36;
const _apiv2GetLastRwStatus = 0x3b;
const _apiv2DriveNrst = 0x3c;
const _apiv2GetLastRwStatus2 = 0x3e;
const _apiv2Readmem16 = 0x47;
const _apiv2Writemem16 = 0x48;
const _debugEnterSwd = 0xa3;

const _statusOk = 0x80;

const _statusNames = <int, String>{
  0x10: 'SWD_AP_WAIT',
  0x11: 'SWD_AP_FAULT',
  0x12: 'SWD_AP_ERROR',
  0x14: 'SWD_DP_WAIT',
  0x15: 'SWD_DP_FAULT',
  0x16: 'SWD_DP_ERROR',
  0x19: 'SWD_AP_STICKY_ERROR',
  0x1a: 'SWD_AP_STICKYORUN_ERROR',
};

// ST-Link core register indices
const regR0 = 0;
const regR1 = 1;
const regR2 = 2;
const regR3 = 3;
const regSp = 13;
const regLr = 14;
const regPc = 15;
const regXpsr = 16;

const _modeDfu = 0x00;

const _maxRw32 = 1024;
const _maxRw8 = 64;

class ProbeVersion {
  ProbeVersion(this.stlink, this.jtag, this.swim, this.text);
  final int stlink;
  final int jtag;
  final int swim;
  final String text;
}

class Stlink {
  Stlink(this._usb);
  final UsbTransport _usb;

  ProbeVersion version = ProbeVersion(0, 0, 0, '?');

  String get probeName => _usb.productName;

  /// Native 16-bit memory access: all V3, or V2 firmware >= J26.
  bool get hasMem16 => _usb.isV3 || version.jtag >= 26;

  Future<void> init() async {
    await _readVersion();
    if (!_usb.isV3 && version.jtag < 15) {
      throw SwdException(
        'ST-Link firmware too old (J${version.jtag}); APIv2 needs J15+.',
      );
    }
    final mode = await getCurrentMode();
    if (mode == _modeDfu) {
      await _usb.xfer([_cmdDfu, _dfuExit]);
      await sleep(50);
    }
  }

  Future<void> _readVersion() async {
    if (_usb.isV3) {
      final rx = await _usb.xfer([_cmdGetVersionV3], rxLen: 12);
      version = ProbeVersion(rx[0], rx[2], rx[1], 'V${rx[0]}J${rx[2]}');
    } else {
      final rx = await _usb.xfer([_cmdGetVersion], rxLen: 6);
      final v = (rx[0] << 8) | rx[1];
      version = ProbeVersion(v >> 12, (v >> 6) & 0x3f, v & 0x3f, 'V${v >> 12}J${(v >> 6) & 0x3f}');
    }
  }

  Future<int> getCurrentMode() async {
    final rx = await _usb.xfer([_cmdGetCurrentMode], rxLen: 2);
    return rx[0];
  }

  Future<double?> getTargetVoltage() async {
    final rx = await _usb.xfer([_cmdGetTargetVoltage], rxLen: 8);
    final adcRef = u32le(rx, 0);
    final adcVdd = u32le(rx, 4);
    if (adcRef == 0) return null;
    return 2 * adcVdd * (1.2 / adcRef);
  }

  void _checkStatus(Uint8List rx, String what) {
    if (rx.isEmpty) return;
    if (rx[0] != _statusOk) {
      final name = _statusNames[rx[0]] ?? 'unknown';
      throw SwdException('$what failed: ST-Link status 0x${rx[0].toRadixString(16)} ($name)');
    }
  }

  Future<void> enterSwd() async {
    final rx = await _usb.xfer([_cmdDebug, _apiv2Enter, _debugEnterSwd], rxLen: 2);
    _checkStatus(rx, 'enter SWD');
  }

  Future<void> exitDebug() async {
    await _usb.xfer([_cmdDebug, _debugExit]);
  }

  Future<int> readIdcode() async {
    final rx = await _usb.xfer([_cmdDebug, _apiv2ReadIdcodes], rxLen: 12);
    _checkStatus(rx, 'read IDCODE');
    return u32le(rx, 4);
  }

  Future<void> resetSys() async {
    final rx = await _usb.xfer([_cmdDebug, _apiv2Resetsys], rxLen: 2);
    _checkStatus(rx, 'reset');
  }

  /// Drive NRST: 0 = low (reset), 1 = high, 2 = pulse.
  Future<void> driveNrst(int state) async {
    final rx = await _usb.xfer([_cmdDebug, _apiv2DriveNrst, state], rxLen: 2);
    _checkStatus(rx, 'drive NRST');
  }

  Future<int> readReg(int index) async {
    final rx = await _usb.xfer([_cmdDebug, _apiv2Readreg, index], rxLen: 8);
    _checkStatus(rx, 'read core reg $index');
    return u32le(rx, 4);
  }

  Future<void> writeReg(int index, int value) async {
    final rx = await _usb.xfer([_cmdDebug, _apiv2Writereg, index, ...u32(value)], rxLen: 2);
    _checkStatus(rx, 'write core reg $index');
  }

  Future<int> readDebugReg(int address) async {
    final rx = await _usb.xfer([_cmdDebug, _apiv2Readdebugreg, ...u32(address)], rxLen: 8);
    _checkStatus(rx, 'read ${hex(address)}');
    return u32le(rx, 4);
  }

  Future<void> writeDebugReg(int address, int value) async {
    final rx =
        await _usb.xfer([_cmdDebug, _apiv2Writedebugreg, ...u32(address), ...u32(value)], rxLen: 2);
    _checkStatus(rx, 'write ${hex(address)}');
  }

  Future<void> _checkLastRwStatus(String what) async {
    if (_usb.isV3 || version.jtag >= 15) {
      final rx = await _usb.xfer([_cmdDebug, _apiv2GetLastRwStatus2], rxLen: 12);
      _checkStatus(rx, what);
    } else {
      final rx = await _usb.xfer([_cmdDebug, _apiv2GetLastRwStatus], rxLen: 2);
      _checkStatus(rx, what);
    }
  }

  Future<Uint8List> readMem32(int address, int length) async {
    if (address % 4 != 0 || length % 4 != 0) {
      throw SwdException('readMem32 requires 4-byte alignment');
    }
    final result = Uint8List(length);
    var done = 0;
    while (done < length) {
      final chunk = length - done < _maxRw32 ? length - done : _maxRw32;
      final rx = await _usb
          .xfer([_cmdDebug, _debugReadmem32, ...u32(address + done), ...u16(chunk)], rxLen: chunk);
      if (rx.length != chunk) throw SwdException('short read: ${rx.length}/$chunk');
      result.setRange(done, done + chunk, rx);
      await _checkLastRwStatus('read ${hex(address + done)}');
      done += chunk;
    }
    return result;
  }

  Future<void> writeMem32(int address, Uint8List dataBuf) async {
    if (address % 4 != 0 || dataBuf.length % 4 != 0) {
      throw SwdException('writeMem32 requires 4-byte alignment');
    }
    var done = 0;
    while (done < dataBuf.length) {
      final chunk = dataBuf.length - done < _maxRw32 ? dataBuf.length - done : _maxRw32;
      await _usb.xfer(
        [_cmdDebug, _debugWritemem32, ...u32(address + done), ...u16(chunk)],
        data: Uint8List.sublistView(dataBuf, done, done + chunk),
      );
      await _checkLastRwStatus('write ${hex(address + done)}');
      done += chunk;
    }
  }

  Future<Uint8List> readMem8(int address, int length) async {
    final result = Uint8List(length);
    var done = 0;
    while (done < length) {
      final chunk = length - done < _maxRw8 ? length - done : _maxRw8;
      final rx = await _usb
          .xfer([_cmdDebug, _debugReadmem8, ...u32(address + done), ...u16(chunk)], rxLen: chunk);
      result.setRange(done, done + chunk, rx);
      await _checkLastRwStatus('read8 ${hex(address + done)}');
      done += chunk;
    }
    return result;
  }

  /// Byte-wise memory write for unaligned accesses (small transfers).
  Future<void> writeMem8(int address, Uint8List dataBuf) async {
    var done = 0;
    while (done < dataBuf.length) {
      final chunk = dataBuf.length - done < _maxRw8 ? dataBuf.length - done : _maxRw8;
      await _usb.xfer(
        [_cmdDebug, _debugWritemem8, ...u32(address + done), ...u16(chunk)],
        data: Uint8List.sublistView(dataBuf, done, done + chunk),
      );
      await _checkLastRwStatus('write8 ${hex(address + done)}');
      done += chunk;
    }
  }

  Future<void> writeU16(int address, int value) async {
    if (!hasMem16) {
      throw SwdException(
        'this ST-Link firmware lacks 16-bit memory access (needs V2 J26+ or V3)',
      );
    }
    if (address % 2 != 0) throw SwdException('writeU16 requires halfword alignment');
    await _usb.xfer(
      [_cmdDebug, _apiv2Writemem16, ...u32(address), ...u16(2)],
      data: Uint8List.fromList([value & 0xff, (value >> 8) & 0xff]),
    );
    await _checkLastRwStatus('write16 ${hex(address)}');
  }

  Future<int> readU16(int address) async {
    if (!hasMem16) throw SwdException('this ST-Link firmware lacks 16-bit memory access');
    final rx = await _usb.xfer([_cmdDebug, _apiv2Readmem16, ...u32(address), ...u16(2)], rxLen: 2);
    await _checkLastRwStatus('read16 ${hex(address)}');
    return rx[0] | (rx[1] << 8);
  }

  Future<void> close() async {
    try {
      await exitDebug();
    } catch (_) {}
    await _usb.close();
  }
}
