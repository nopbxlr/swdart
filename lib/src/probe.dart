// The high-level facade: connect to a target over an ST-Link, then debug
// (halt/step/registers/memory) and program (erase/write/verify/protection) it.
import 'dart:async';
import 'dart:typed_data';

import 'cortexm.dart';
import 'flash.dart';
import 'stlink.dart';
import 'targets.dart';
import 'transport.dart';
import 'transport_open.dart';
import 'util.dart';

/// How to attach to the target.
enum ConnectMode {
  /// Plain SWD attach to a running (or already-halted) core.
  normal,

  /// Assert the hardware reset (nRST) line, attach, catch the core at the reset
  /// vector, then release — for firmware that reconfigures/disables the SWD
  /// pins once it runs.
  underReset,

  /// Like [underReset], but reset is held and the library emits a prompt and
  /// waits for [Probe.continueConnect] before releasing — for probes/targets
  /// where the operator performs a manual step (grounding a reset test point,
  /// etc.) between assert and release.
  guided,

  /// Respawn the attach in a tight loop until the brief post-power-on window is
  /// caught — for targets that disable SWD very early. Cut and re-apply power;
  /// call [abort] to stop.
  attachRace,
}

/// A named core register value.
class CoreRegister {
  const CoreRegister(this.name, this.value);
  final String name;
  final int value;
}

const _flashBase = 0x08000000;
const _fallbackLen = 0x20000; // fallback when the chip's flash size can't be read
const _dbgmcuCr = 0xe0042004;

/// A debug/programming session with one target over one ST-Link probe.
///
/// ```dart
/// final probe = Probe()..onLog(print);
/// final target = await probe.connect(ConnectMode.underReset);
/// await probe.program(0x08000000, firmwareBytes);   // erase + write + verify
/// await probe.resetRun();
/// await probe.disconnect();
/// ```
class Probe {
  Probe();

  UsbTransport? _usb;
  Stlink? _stlink;
  CortexM? _core;
  TargetInfo? _target;
  FlashDriver? _driver;

  void Function(String line)? _log;
  Completer<void>? _continueGate;
  bool _stop = false;

  /// True once attached to a target.
  bool get isConnected => _stlink != null;

  /// The detected target, or null when not connected.
  TargetInfo? get target => _target;

  /// Human-readable probe name, e.g. "ST-Link/V2".
  String get probeName => _stlink?.probeName ?? '?';

  /// Whether the probe supports 16-bit memory access (needed for some option
  /// bytes); all V3, or V2 firmware >= J26.
  bool get hasMem16 => _stlink?.hasMem16 ?? false;

  /// Receive human-readable progress/status lines.
  void onLog(void Function(String line) sink) => _log = sink;
  void _emit(String line) => _log?.call(line);

  // ── connection ────────────────────────────────────────────────────────
  /// Open the probe (if needed) and attach to the target.
  Future<TargetInfo> connect(ConnectMode mode) async {
    if (mode == ConnectMode.attachRace) return _connectRace();
    await _openProbe();
    final p = _stlink!;
    final underReset = mode == ConnectMode.underReset || mode == ConnectMode.guided;

    if (underReset) {
      _emit('[connect] ${mode.name}: asserting nRST');
      await p.driveNrst(0);
      if (mode == ConnectMode.guided) {
        _emit('== target held in reset — perform the manual step, then call continueConnect() ==');
        await _waitContinue();
      }
    }
    await p.enterSwd();
    final idcode = await p.readIdcode();
    _emit('[connect] SWD IDCODE ${hex(idcode)}');

    _core = CortexM(p);
    if (underReset) {
      await _core!.halt();
      await p.writeDebugReg(demcr, 1); // VC_CORERESET: catch the reset vector
      await p.driveNrst(1);
      await _core!.waitHalted();
      await p.writeDebugReg(demcr, 0);
      _emit('[connect] core halted at reset vector');
    }
    return _finishAttach();
  }

  Future<TargetInfo> _connectRace() async {
    await _openProbe();
    final p = _stlink!;
    _stop = false;
    var attempt = 0;
    for (;;) {
      if (_stop) throw SwdException('attach-race aborted');
      attempt++;
      try {
        await p.enterSwd();
        final idcode = await p.readIdcode();
        if (idcode == 0) throw SwdException('idcode 0');
        _emit('== caught on attempt $attempt; hold power ==');
        _core = CortexM(p);
        await _core!.halt();
        await _core!.waitHalted(1500);
        return _finishAttach();
      } catch (_) {
        if (attempt % 20 == 0) _emit('[race] $attempt attempts…');
        await sleep(5);
      }
    }
  }

  /// Release a [ConnectMode.guided] connect. Returns false if none is waiting.
  bool continueConnect() {
    final g = _continueGate;
    if (g != null && !g.isCompleted) {
      _continueGate = null;
      g.complete();
      return true;
    }
    return false;
  }

  /// Abort an in-progress [ConnectMode.attachRace].
  void abort() => _stop = true;

  Future<void> _openProbe() async {
    if (_stlink != null) return;
    // Reuse an already-granted probe without a prompt where possible (WebUSB);
    // fall back to a picker/enumeration otherwise.
    _usb = await reacquireStlink() ?? await requestStlink();
    final p = Stlink(_usb!);
    await p.init();
    _stlink = p;
    _emit('[probe] ${p.probeName} (${p.version.text})${p.hasMem16 ? ", 16-bit" : ""}');
  }

  Future<TargetInfo> _finishAttach() async {
    final p = _stlink!;
    await _freezeWatchdogs(p);
    _target = await detectTarget(p, _core!);
    _driver = _target!.family == 'unknown' ? null : _makeDriver();
    _emit('[target] ${_target!.name}');
    final voltage = await p.getTargetVoltage().catchError((_) => null);
    if (voltage != null) _emit('[target] Vtarget ${voltage.toStringAsFixed(2)} V');
    return _target!;
  }

  /// Freeze the independent + window watchdogs (and low-power modes) while the
  /// core is halted, so a running IWDG/WWDG from the target's own firmware can't
  /// reset the chip mid-operation. Mirrors OpenOCD's `mmw 0xE0042004 0x307`
  /// (DBG_WWDG_STOP | DBG_IWDG_STOP | DBG_STANDBY | DBG_STOP | DBG_SLEEP). The
  /// DBGMCU/DEBUG control register is not reset by system reset, so once is
  /// enough. Layout shared by STM32F1 and AT32.
  Future<void> _freezeWatchdogs(Stlink p) async {
    try {
      final cur = await p.readDebugReg(_dbgmcuCr);
      await p.writeDebugReg(_dbgmcuCr, cur | 0x307);
      _emit('[debug] watchdogs frozen while halted');
    } catch (_) {
      // Non-fatal.
    }
  }

  FlashDriver _makeDriver() {
    final t = _target!;
    if (t.family == 'AT32') return At32Flash(_stlink!, _core!, t.pageSize, t.sramBytes);
    if (t.family == 'STM32') {
      return Stm32f1Flash(_stlink!, _core!, t.pageSize, t.sramBytes, rdpDisable: t.rdpDisableValue);
    }
    throw SwdException('no flash driver for target family "${t.family}"');
  }

  CortexM get _c {
    final c = _core;
    if (c == null) throw SwdException('not connected');
    return c;
  }

  Stlink get _p {
    final p = _stlink;
    if (p == null) throw SwdException('not connected');
    return p;
  }

  FlashDriver get _drv {
    final d = _driver;
    if (!isConnected) throw SwdException('not connected');
    if (d == null) throw SwdException('no flash driver for ${_target?.family}');
    return d;
  }

  // ── execution control ─────────────────────────────────────────────────
  Future<bool> isHalted() => _c.isHalted();
  Future<void> halt() => _c.halt();
  Future<void> resume() => _c.resume();
  Future<void> step() => _c.step();

  /// Reset and catch the core halted at the reset vector.
  Future<void> resetHalt() async {
    await _c.resetHalt();
    _emit('[target] reset halt');
  }

  /// Reset the target and let it run.
  Future<void> resetRun() async {
    await _c.resetRun();
    _emit('[target] reset, running');
  }

  Future<int> readPc() => _c.readPc();

  /// Read r0–r12, sp, lr, pc, xpsr (halts the core if it isn't already).
  Future<List<CoreRegister>> readRegisters() async {
    if (!await _c.isHalted()) await _c.halt();
    final regs = await _c.readAllRegs();
    return [for (final r in regs) CoreRegister(r.name, r.value)];
  }

  /// Read one core register by ST-Link index (0–15 = r0–pc, 16 = xPSR).
  Future<int> readRegister(int index) => _p.readReg(index);

  /// Write one core register by ST-Link index.
  Future<void> writeRegister(int index, int value) => _p.writeReg(index, value);

  // ── memory ────────────────────────────────────────────────────────────
  /// Read [length] bytes from any address (handles unaligned reads via a 32-bit
  /// aligned superset).
  Future<Uint8List> readMemory(int address, int length) async {
    if (length == 0) return Uint8List(0);
    final start = address & ~3;
    final end = (address + length + 3) & ~3;
    final raw = await _p.readMem32(start, end - start);
    return Uint8List.sublistView(raw, address - start, address - start + length);
  }

  /// Write [data] to any address (32-bit path when aligned, byte path
  /// otherwise). Note: memory-mapped peripherals may require aligned width.
  Future<void> writeMemory(int address, Uint8List data) async {
    if (address % 4 == 0 && data.length % 4 == 0) {
      await _p.writeMem32(address, data);
    } else {
      await _p.writeMem8(address, data);
    }
  }

  // ── flash programming ─────────────────────────────────────────────────
  /// Read flash. [address] defaults to the target's flash base and [length] to
  /// the detected flash size (falling back to 128 KB only if the size is
  /// unreadable).
  Future<Uint8List> readFlash({int? address, int? length}) async {
    await halt();
    final base = address ?? _target?.flashBase ?? _flashBase;
    final kb = _target?.flashKB ?? 0;
    final len = length ?? (kb > 0 ? kb * 1024 : _fallbackLen);
    _emit('[flash] reading $len bytes from ${hex(base)}');
    return readMemory(base, len);
  }

  /// Mass-erase the whole flash.
  Future<void> eraseAll() async {
    await resetHalt();
    await _drv.massErase();
    _emit('[flash] mass erased');
  }

  /// Erase the pages covering [address]..[address]+[length].
  Future<void> erase(int address, int length, {ProgressFn? progress}) async {
    await resetHalt();
    await _drv.erase(address, length, progress);
    _emit('[flash] erased ${hex(address)} +$length');
  }

  /// Write [data] to flash at [address] without erasing first.
  Future<void> writeFlash(int address, Uint8List data, {ProgressFn? progress}) async {
    if (!await _c.isHalted()) await _c.halt();
    await _drv.program(address, data, progress);
    _emit('[flash] wrote ${data.length} bytes @ ${hex(address)}');
  }

  /// Verify flash against [data] by read-back.
  Future<void> verifyFlash(int address, Uint8List data, {ProgressFn? progress}) async {
    if (!await _c.isHalted()) await _c.halt();
    await _drv.verify(address, data, progress);
    _emit('[flash] verified ${data.length} bytes @ ${hex(address)}');
  }

  /// High-level program: reset-halt, erase the covered pages, write, and (by
  /// default) verify. The one call most callers want.
  Future<void> program(
    int address,
    Uint8List data, {
    bool eraseFirst = true,
    bool verify = true,
    ProgressFn? progress,
  }) async {
    await resetHalt();
    if (eraseFirst) {
      await _drv.erase(address, data.length, progress);
      _emit('[flash] erased');
    }
    await _drv.program(address, data, progress);
    _emit('[flash] wrote ${data.length} bytes');
    if (verify) {
      await _drv.verify(address, data, progress);
      _emit('[flash] verified');
    }
  }

  // ── read/flash protection ─────────────────────────────────────────────
  /// Read the target's read/flash-access-protection state (RDP / FAP).
  Future<ProtectionState> readProtection() => _drv.readProtection();

  /// Enable or disable read protection. Disabling always mass-erases the chip
  /// (the security guarantee) — the recovery path for a device locked by its
  /// own firmware.
  Future<ProtectionResult> setProtection(bool enable) async {
    await resetHalt();
    final res = await _drv.setProtection(enable);
    _emit('[protection] ${res.message}');
    return res;
  }

  // ── lifecycle ─────────────────────────────────────────────────────────
  Future<void> disconnect() async {
    _stop = true;
    try {
      await _stlink?.close();
    } catch (_) {}
    _stlink = null;
    _core = null;
    _driver = null;
    _target = null;
    _usb = null;
    _emit('[probe] disconnected');
  }

  Future<void> _waitContinue() {
    final g = Completer<void>();
    _continueGate = g;
    return g.future;
  }
}
