// Flash drivers ported from openocd-ts (src/flash/{driver,at32,stm32f1}.ts).
// Register sequences follow OpenOCD's own drivers (artery.c / stm32f1x.c) —
// behavior only, no code copied.
import 'dart:typed_data';

import 'cortexm.dart';
import 'debug_probe.dart';
import 'loader.dart';
import 'util.dart';

typedef ProgressFn = void Function(int done, int total);

class ProtectionState {
  ProtectionState(this.enabled, this.level);
  final bool enabled;
  final String level;
}

class ProtectionResult {
  ProtectionResult({
    required this.massErased,
    required this.resetRequired,
    required this.autoReset,
    required this.message,
  });
  final bool massErased;
  final bool resetRequired;
  final bool autoReset;
  final String message;
}

abstract class FlashDriver {
  int get programAlign;
  Future<void> massErase();
  Future<void> erase(int address, int length, [ProgressFn? progress]);
  Future<void> program(int address, Uint8List data, [ProgressFn? progress]);
  Future<void> verify(int address, Uint8List data, [ProgressFn? progress]);
  Future<ProtectionState> readProtection();
  Future<ProtectionResult> setProtection(bool enable);
}

// ── Shared plumbing for the ST/GigaDevice FPEC and the register-compatible ─────
// Artery FMC. Both run a tiny SRAM loader out of a work buffer and poll BSY at
// the same status register (0x4002200C bit 0). The families diverge on unlock,
// erase, program width and protection — that logic stays in the subclasses.
const _fpecStatus = 0x40022000 + 0x0c;
const _fpecBusy = 1 << 0;

abstract class _FpecFlash implements FlashDriver {
  _FpecFlash(DebugProbe probe, CortexM core, int pageSize, int sramBytes)
      : _probe = probe,
        _core = core,
        _pageSize = pageSize,
        _bufferSize = (() {
          final s = ((sramBytes - 0x400) >> 2) << 2;
          return s < 0x2000 ? s : 0x2000;
        })() {
    if (_bufferSize < 0x400) throw SwdException('target SRAM too small for flash loader');
  }

  final DebugProbe _probe;
  final CortexM _core;
  final int _pageSize;
  final int _bufferSize;
  final int _loaderAddr = 0x20000000;
  final int _bufferAddr = 0x20000100;

  /// Poll the FPEC status register until BSY clears; returns the final status.
  Future<int> _waitBusy(int timeoutMs) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    for (;;) {
      final sr = await _probe.readDebugReg(_fpecStatus);
      if ((sr & _fpecBusy) == 0) return sr;
      if (DateTime.now().isAfter(deadline)) throw SwdException('flash busy after $timeoutMs ms');
      await sleep(2);
    }
  }

  @override
  Future<void> verify(int address, Uint8List data, [ProgressFn? progress]) =>
      _verifyCommon(_probe, address, data, progress);
}

// ─────────────────────────── AT32F415 (Artery FMC) ───────────────────────────
const _atBase = 0x40022000;
const _atUnlock = _atBase + 0x04;
const _atUsdUnlock = _atBase + 0x08;
const _atSts = _atBase + 0x0c;
const _atCtrl = _atBase + 0x10;
const _atAddr = _atBase + 0x14;
const _atUsdReg = _atBase + 0x1c;

const _key1 = 0x45670123;
const _key2 = 0xcdef89ab;

const _ctrlFprgm = 1 << 0;
const _ctrlSecers = 1 << 1;
const _ctrlBankers = 1 << 2;
const _ctrlUsdprgm = 1 << 4;
const _ctrlUsders = 1 << 5;
const _ctrlErstr = 1 << 6;
const _ctrlOplk = 1 << 7;
const _ctrlUsdulks = 1 << 9;

const _stsPrgmerr = 1 << 2;
const _stsEpperr = 1 << 4;

const _usdFap = 1 << 1;
const _usdFapHl = 1 << 26;

const _fapDisabled = 0xa5;
const _fapLow = 0xff;

const _crmCtrl = 0x40021000;
const _crmHicken = 1 << 1;
const _crmHickstbl = 1 << 0;

const _usdBase = 0x1ffff800;

class At32Flash extends _FpecFlash {
  At32Flash(super.probe, super.core, super.pageSize, super.sramBytes, {this.hasFapHighLevel = true});

  final bool hasFapHighLevel;

  @override
  int get programAlign => 4;

  Future<void> _enableHick() async {
    var ctrl = await _probe.readDebugReg(_crmCtrl);
    if (ctrl & _crmHickstbl != 0) return;
    await _probe.writeDebugReg(_crmCtrl, ctrl | _crmHicken);
    final deadline = DateTime.now().add(const Duration(seconds: 1));
    do {
      ctrl = await _probe.readDebugReg(_crmCtrl);
      if (ctrl & _crmHickstbl != 0) return;
      await sleep(2);
    } while (DateTime.now().isBefore(deadline));
    throw SwdException('AT32 HICK clock did not stabilize');
  }

  Future<void> _unlockFlash() async {
    if ((await _probe.readDebugReg(_atCtrl) & _ctrlOplk) == 0) return;
    await _probe.writeDebugReg(_atUnlock, _key1);
    await _probe.writeDebugReg(_atUnlock, _key2);
    if (await _probe.readDebugReg(_atCtrl) & _ctrlOplk != 0) {
      throw SwdException('AT32 flash unlock failed (OPLK still set)');
    }
  }

  Future<void> _unlockUsd() async {
    if (await _probe.readDebugReg(_atCtrl) & _ctrlUsdulks != 0) return;
    await _probe.writeDebugReg(_atUsdUnlock, _key1);
    await _probe.writeDebugReg(_atUsdUnlock, _key2);
    if (await _probe.readDebugReg(_atCtrl) & _ctrlUsdulks == 0) {
      throw SwdException('AT32 user-system-data unlock failed');
    }
  }

  Future<void> _initFlash() async {
    await _enableHick();
    await _unlockFlash();
    await _unlockUsd();
  }

  Future<void> _deinitFlash() async {
    var ctrl = await _probe.readDebugReg(_atCtrl);
    if (ctrl & _ctrlUsdulks != 0) await _probe.writeDebugReg(_atCtrl, ctrl & ~_ctrlUsdulks);
    ctrl = await _probe.readDebugReg(_atCtrl);
    if (ctrl & _ctrlOplk == 0) await _probe.writeDebugReg(_atCtrl, ctrl | _ctrlOplk);
  }

  void _checkErr(int sts, String what) {
    if (sts & _stsEpperr != 0) throw SwdException('$what: erase/program protection error (EPPERR)');
    if (sts & _stsPrgmerr != 0) throw SwdException('$what: programming error (PRGMERR)');
  }

  @override
  Future<void> massErase() async {
    await _initFlash();
    try {
      await _waitBusy(50);
      await _probe.writeDebugReg(_atSts, _stsEpperr);
      await _probe.writeDebugReg(_atCtrl, _ctrlBankers | _ctrlErstr);
      _checkErr(await _waitBusy(2400), 'mass erase');
    } finally {
      await _deinitFlash();
    }
  }

  @override
  Future<void> erase(int address, int length, [ProgressFn? progress]) async {
    final first = ((address - 0x08000000) / _pageSize).floor();
    final last = (((address + length - 0x08000000) / _pageSize).ceil()) - 1;
    final total = last - first + 1;
    await _initFlash();
    try {
      await _probe.writeDebugReg(_atSts, _stsEpperr);
      await _waitBusy(50);
      var done = 0;
      for (var page = first; page <= last; page++) {
        final pageAddr = 0x08000000 + page * _pageSize;
        await _probe.writeDebugReg(_atAddr, pageAddr);
        await _probe.writeDebugReg(_atCtrl, _ctrlSecers | _ctrlErstr);
        _checkErr(await _waitBusy(500), 'erase page ${hex(pageAddr)}');
        progress?.call(++done, total);
      }
    } finally {
      await _deinitFlash();
    }
  }

  @override
  Future<void> program(int address, Uint8List data, [ProgressFn? progress]) async {
    if (address % 4 != 0) throw SwdException('AT32 program address must be word-aligned');
    if (!await _core.isHalted()) throw SwdException('core must be halted to program flash');

    final padded = Uint8List(((data.length + 3) >> 2) << 2)..fillRange(0, ((data.length + 3) >> 2) << 2, 0xff);
    padded.setRange(0, data.length, data);

    await _initFlash();
    try {
      await _probe.writeDebugReg(_atSts, _stsPrgmerr);
      await _probe.writeDebugReg(_atCtrl, _ctrlFprgm);
      final total = padded.length;
      var done = 0;
      while (done < total) {
        final chunkLen = (total - done) < _bufferSize ? (total - done) : _bufferSize;
        await _probe.writeMem32(_bufferAddr, Uint8List.sublistView(padded, done, done + chunkLen));
        await runLoader(_probe, _core, wordLoader,
            loaderAddr: _loaderAddr, srcAddr: _bufferAddr, dstAddr: address + done, count: chunkLen >> 2);
        _checkErr(await _probe.readDebugReg(_atSts), 'program at ${hex(address + done)}');
        done += chunkLen;
        progress?.call(done, total);
      }
      await _probe.writeDebugReg(_atCtrl, 0);
    } finally {
      await _deinitFlash();
    }
  }

  @override
  Future<ProtectionState> readProtection() async {
    final usd = await _probe.readDebugReg(_atUsdReg);
    final fapLow = usd & _usdFap != 0;
    final fapHigh = hasFapHighLevel && (usd & _usdFapHl != 0);
    if (fapHigh && fapLow) return ProtectionState(true, 'high (FAP)');
    if (fapLow) return ProtectionState(true, 'low (FAP)');
    return ProtectionState(false, 'disabled');
  }

  @override
  Future<ProtectionResult> setProtection(bool enable) => enable ? _enableFap() : _disableFap();

  /// Disable FAP. Erases USD, writes FAP=0xA5 (0x5AA5) as a
  /// single 16-bit access to 0x1FFFF800; the device mass-erases and resets.
  Future<ProtectionResult> _disableFap() async {
    await _initFlash();
    await _waitBusy(50);
    await _probe.writeDebugReg(_atCtrl, _ctrlUsdulks | _ctrlUsders | _ctrlErstr);
    await _waitBusy(50);
    await _probe.writeDebugReg(_atSts, _stsPrgmerr);
    await _probe.writeDebugReg(_atCtrl, _ctrlUsdulks | _ctrlUsdprgm);
    await _waitBusy(50);
    final fapHalfword = _fapDisabled | ((~_fapDisabled & 0xff) << 8); // 0x5AA5
    try {
      await _probe.writeU16(_usdBase, fapHalfword);
    } catch (_) {
      // device reset during/after the write — expected
    }
    return ProtectionResult(
      massErased: true,
      resetRequired: false,
      autoReset: true,
      message: 'FAP disabled: the chip erased its flash and reset. Power-cycle the board, then reconnect.',
    );
  }

  Future<ProtectionResult> _enableFap() async {
    final usdImage = await _probe.readMem32(_usdBase, 16);
    await _initFlash();
    try {
      await _waitBusy(50);
      await _probe.writeDebugReg(_atCtrl, _ctrlUsdulks | _ctrlUsders | _ctrlErstr);
      await _waitBusy(50);
      await _probe.writeDebugReg(_atSts, _stsPrgmerr);
      await _probe.writeDebugReg(_atCtrl, _ctrlUsdulks | _ctrlUsdprgm);
      await _waitBusy(50);
      await _probe.writeU16(_usdBase, _fapLow | ((~_fapLow & 0xff) << 8));
      await _waitBusy(50);
      for (var off = 2; off < 16; off += 2) {
        final word = u32le(usdImage, off & ~3);
        final halfword = (off & 2) == 0 ? word & 0xffff : (word >> 16) & 0xffff;
        if (halfword != 0xffff) {
          await _probe.writeU16(_usdBase + off, halfword);
          await _waitBusy(50);
        }
      }
      _checkErr(await _probe.readDebugReg(_atSts), 'enable FAP');
    } finally {
      await _deinitFlash();
    }
    return ProtectionResult(
      massErased: false,
      resetRequired: true,
      autoReset: false,
      message: 'FAP enabled. Power-cycle the board for read protection to take effect.',
    );
  }
}

// ─────────────────────────── STM32F1 (FPEC) ───────────────────────────
const _f1Base = 0x40022000;
const _f1Keyr = _f1Base + 0x04;
const _f1Optkeyr = _f1Base + 0x08;
const _f1Sr = _f1Base + 0x0c;
const _f1Cr = _f1Base + 0x10;
const _f1Ar = _f1Base + 0x14;
const _f1Obr = _f1Base + 0x1c;

const _crPg = 1 << 0;
const _crPer = 1 << 1;
const _crMer = 1 << 2;
const _crOptpg = 1 << 4;
const _crOpter = 1 << 5;
const _crStrt = 1 << 6;
const _crLock = 1 << 7;
const _crOptwre = 1 << 9;

const _srPgerr = 1 << 2;
const _srWrprterr = 1 << 4;
const _srEop = 1 << 5;

const _obrOptReadout = 1 << 1;
const _obRdp = 0x1ffff800;
const _rdpUnprotect = 0xa5;

class Stm32f1Flash extends _FpecFlash {
  Stm32f1Flash(super.probe, super.core, super.pageSize, super.sramBytes,
      {int rdpDisable = _rdpUnprotect, bool word = false})
      : _rdpDisable = rdpDisable,
        _word = word;

  /// Value written to the RDP option byte to remove read protection
  /// (0xA5 on STM32F1, 0xAA on STM32F0/F3).
  final int _rdpDisable;

  /// True for FMCs that program in 32-bit words instead of 16-bit halfwords
  /// (GigaDevice GD32E103 — same FPEC registers, word-width data).
  final bool _word;

  @override
  int get programAlign => _word ? 4 : 2;

  void _checkErr(int sr, String what) {
    if (sr & _srWrprterr != 0) throw SwdException('$what: write-protection error (WRPRTERR)');
    if (sr & _srPgerr != 0) throw SwdException('$what: programming error (PGERR)');
  }

  Future<void> _unlock() async {
    if (await _probe.readDebugReg(_f1Cr) & _crLock != 0) {
      await _probe.writeDebugReg(_f1Keyr, _key1);
      await _probe.writeDebugReg(_f1Keyr, _key2);
      if (await _probe.readDebugReg(_f1Cr) & _crLock != 0) {
        throw SwdException('STM32F1 flash unlock failed (CR.LOCK still set)');
      }
    }
  }

  Future<void> _unlockOptions() async {
    if (await _probe.readDebugReg(_f1Cr) & _crOptwre != 0) return;
    await _probe.writeDebugReg(_f1Optkeyr, _key1);
    await _probe.writeDebugReg(_f1Optkeyr, _key2);
  }

  Future<void> _clearStatus() => _probe.writeDebugReg(_f1Sr, _srEop | _srPgerr | _srWrprterr);

  @override
  Future<void> massErase() async {
    await _unlock();
    await _clearStatus();
    await _probe.writeDebugReg(_f1Cr, _crMer);
    await _probe.writeDebugReg(_f1Cr, _crMer | _crStrt);
    final sr = await _waitBusy(30000);
    await _probe.writeDebugReg(_f1Cr, 0);
    _checkErr(sr, 'mass erase');
  }

  @override
  Future<void> erase(int address, int length, [ProgressFn? progress]) async {
    final first = (address ~/ _pageSize) * _pageSize;
    final last = ((address + length + _pageSize - 1) ~/ _pageSize) * _pageSize;
    final total = (last - first) ~/ _pageSize;
    await _unlock();
    await _clearStatus();
    var done = 0;
    for (var page = first; page < last; page += _pageSize) {
      await _probe.writeDebugReg(_f1Cr, _crPer);
      await _probe.writeDebugReg(_f1Ar, page);
      await _probe.writeDebugReg(_f1Cr, _crPer | _crStrt);
      _checkErr(await _waitBusy(3000), 'erase page ${hex(page)}');
      progress?.call(++done, total);
    }
    await _probe.writeDebugReg(_f1Cr, 0);
  }

  @override
  Future<void> program(int address, Uint8List data, [ProgressFn? progress]) async {
    final align = _word ? 4 : 2;
    if (address % align != 0) {
      throw SwdException('program address must be ${_word ? 'word' : 'halfword'}-aligned');
    }
    if (!await _core.isHalted()) throw SwdException('core must be halted to program flash');

    final padLen = ((data.length + align - 1) ~/ align) * align;
    final padded = Uint8List(padLen)..fillRange(0, padLen, 0xff);
    padded.setRange(0, data.length, data);

    await _unlock();
    await _clearStatus();
    final total = padded.length;
    var done = 0;
    while (done < total) {
      final chunkLen = (total - done) < _bufferSize ? (total - done) : _bufferSize;
      final wordLen = ((chunkLen + 3) >> 2) << 2;
      final chunk = Uint8List(wordLen)..fillRange(0, wordLen, 0xff);
      chunk.setRange(0, chunkLen, Uint8List.sublistView(padded, done, done + chunkLen));
      await _probe.writeMem32(_bufferAddr, chunk);

      await _probe.writeDebugReg(_f1Cr, _crPg);
      // Same FPEC PG sequence; GD32E103 copies 32-bit words, STM32 16-bit halfwords.
      await runLoader(_probe, _core, _word ? wordLoader : halfwordLoader,
          loaderAddr: _loaderAddr, srcAddr: _bufferAddr, dstAddr: address + done,
          count: chunkLen >> (_word ? 2 : 1));
      final sr = await _probe.readDebugReg(_f1Sr);
      await _probe.writeDebugReg(_f1Cr, 0);
      _checkErr(sr, 'program at ${hex(address + done)}');
      done += chunkLen;
      progress?.call(done, total);
    }
  }

  @override
  Future<ProtectionState> readProtection() async {
    final active = await _probe.readDebugReg(_f1Obr) & _obrOptReadout != 0;
    return ProtectionState(active, active ? 'level 1 (RDP)' : 'disabled');
  }

  @override
  Future<ProtectionResult> setProtection(bool enable) async {
    final rdp = enable ? 0x00 : _rdpDisable;
    await _eraseOptions();
    await _writeOptions(rdp);
    return enable
        ? ProtectionResult(
            massErased: false,
            resetRequired: true,
            autoReset: false,
            message: 'Read protection (RDP) enabled. Power-cycle for it to take effect.')
        : ProtectionResult(
            massErased: true,
            resetRequired: true,
            autoReset: false,
            message: 'RDP cleared: the chip will mass-erase on the next reset. Power-cycle, then reconnect.');
  }

  Future<void> _eraseOptions() async {
    await _unlock();
    await _unlockOptions();
    await _probe.writeDebugReg(_f1Cr, _crOpter | _crOptwre);
    await _probe.writeDebugReg(_f1Cr, _crOpter | _crStrt | _crOptwre);
    _checkErr(await _waitBusy(3000), 'erase option bytes');
  }

  Future<void> _writeOptions(int rdp) async {
    await _unlock();
    await _unlockOptions();
    final options = Uint8List(16)..fillRange(0, 16, 0xff);
    options[0] = rdp;
    options[1] = 0x00;
    await _probe.writeMem32(_bufferAddr, options);
    await _probe.writeDebugReg(_f1Cr, _crOptpg | _crOptwre);
    // Word mode writes the same 16-byte image as 4 words — word 0 is 0xFFFF00A5
    // for RDP-disable, matching the GD32E103 flasher firmware.
    await runLoader(_probe, _core, _word ? wordLoader : halfwordLoader,
        loaderAddr: _loaderAddr, srcAddr: _bufferAddr, dstAddr: _obRdp, count: _word ? 4 : 8);
    final sr = await _probe.readDebugReg(_f1Sr);
    await _probe.writeDebugReg(_f1Cr, _crLock);
    _checkErr(sr, 'program option bytes');
  }
}

// ─────────────────────── Nordic nRF51 / nRF52 (NVMC) ──────────────────────
// The Non-Volatile Memory Controller programs flash a 32-bit word at a time
// straight through the debug AP — no SRAM loader needed. Register map is shared
// by nRF51 and nRF52; only the page size (1 KB vs 4 KB) and the UICR
// access-protection register differ.
const _nvmcBase = 0x4001e000;
const _nvmcReady = _nvmcBase + 0x400; // bit0 = 1 when idle
const _nvmcConfig = _nvmcBase + 0x504; // 0 read-only, 1 write, 2 erase
const _nvmcErasePage = _nvmcBase + 0x508; // write the page's base address
const _nvmcEraseAll = _nvmcBase + 0x50c; // write 1 to erase code + UICR

const _nvmcRen = 0;
const _nvmcWen = 1;
const _nvmcEen = 2;

// UICR access protection — low byte 0xFF means unprotected.
const _uicrApprotect52 = 0x10001208; // nRF52 APPROTECT
const _uicrRbpconf51 = 0x10001004; //   nRF51 RBPCONF (PALL in bits[7:0])

class NrfFlash implements FlashDriver {
  NrfFlash(this._probe, this._core, this._pageSize, {required this.isNrf52});

  final DebugProbe _probe;
  final CortexM _core;
  final int _pageSize;
  final bool isNrf52;

  int get _protReg => isNrf52 ? _uicrApprotect52 : _uicrRbpconf51;

  @override
  int get programAlign => 4;

  Future<void> _waitReady(int timeoutMs) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    for (;;) {
      if (await _probe.readDebugReg(_nvmcReady) & 1 != 0) return;
      if (DateTime.now().isAfter(deadline)) throw SwdException('nRF NVMC busy after $timeoutMs ms');
      await sleep(1);
    }
  }

  Future<void> _config(int mode) async {
    await _probe.writeDebugReg(_nvmcConfig, mode);
    await _waitReady(100);
  }

  @override
  Future<void> massErase() async {
    await _config(_nvmcEen);
    try {
      await _probe.writeDebugReg(_nvmcEraseAll, 1);
      await _waitReady(30000);
    } finally {
      await _config(_nvmcRen);
    }
  }

  @override
  Future<void> erase(int address, int length, [ProgressFn? progress]) async {
    final first = (address ~/ _pageSize) * _pageSize;
    final last = ((address + length + _pageSize - 1) ~/ _pageSize) * _pageSize;
    final total = (last - first) ~/ _pageSize;
    await _config(_nvmcEen);
    try {
      var done = 0;
      for (var page = first; page < last; page += _pageSize) {
        await _probe.writeDebugReg(_nvmcErasePage, page);
        await _waitReady(1000);
        progress?.call(++done, total);
      }
    } finally {
      await _config(_nvmcRen);
    }
  }

  @override
  Future<void> program(int address, Uint8List data, [ProgressFn? progress]) async {
    if (address % 4 != 0) throw SwdException('nRF program address must be word-aligned');
    if (!await _core.isHalted()) throw SwdException('core must be halted to program flash');

    final padLen = ((data.length + 3) >> 2) << 2;
    final padded = Uint8List(padLen)..fillRange(0, padLen, 0xff);
    padded.setRange(0, data.length, data);
    final total = padded.length;

    await _config(_nvmcWen);
    try {
      for (var off = 0; off < total; off += 4) {
        final word = u32le(padded, off);
        // Flash writes only clear 1->0, so a 0xFFFFFFFF word over freshly-erased
        // flash is a no-op — skip it (a big win for the usual 0xFF padding).
        if (word != 0xffffffff) {
          await _probe.writeDebugReg(address + off, word);
          await _waitReady(500);
        }
        if ((off & 0x3ff) == 0) progress?.call(off, total);
      }
      progress?.call(total, total);
    } finally {
      await _config(_nvmcRen);
    }
  }

  @override
  Future<void> verify(int address, Uint8List data, [ProgressFn? progress]) =>
      _verifyCommon(_probe, address, data, progress);

  @override
  Future<ProtectionState> readProtection() async {
    final v = await _probe.readDebugReg(_protReg);
    final enabled = (v & 0xff) != 0xff;
    final tag = isNrf52 ? 'APPROTECT' : 'RBPCONF';
    return ProtectionState(enabled, enabled ? 'enabled ($tag)' : 'disabled');
  }

  @override
  Future<ProtectionResult> setProtection(bool enable) async {
    if (enable) {
      // Clear the protection byte in UICR (flash: only 1->0, and UICR must be
      // erased/0xFF first). Takes effect after a reset.
      await _config(_nvmcWen);
      try {
        await _probe.writeDebugReg(_protReg, isNrf52 ? 0x00000000 : 0xffffff00);
        await _waitReady(500);
      } finally {
        await _config(_nvmcRen);
      }
      return ProtectionResult(
        massErased: false,
        resetRequired: true,
        autoReset: false,
        message: 'Access protection enabled in UICR. Power-cycle for it to take effect.',
      );
    }
    // Disabling = full chip erase (ERASEALL also clears UICR back to 0xFF).
    await massErase();
    return ProtectionResult(
      massErased: true,
      resetRequired: true,
      autoReset: false,
      message: 'Chip erased (ERASEALL); access protection cleared. A chip already '
          'locked by APPROTECT (debug port disabled) instead needs a CTRL-AP ERASEALL.',
    );
  }
}

// Shared read-back verify.
Future<void> _verifyCommon(DebugProbe probe, int address, Uint8List data, ProgressFn? progress) async {
  final total = data.length;
  var done = 0;
  while (done < total) {
    final chunkLen = (total - done) < 1024 ? (total - done) : 1024;
    final readLen = ((chunkLen + 3) >> 2) << 2;
    final read = await probe.readMem32(address + done, readLen);
    for (var i = 0; i < chunkLen; i++) {
      if (read[i] != data[done + i]) {
        throw SwdException(
          'verify FAILED at ${hex(address + done + i)}: wrote 0x${data[done + i].toRadixString(16).padLeft(2, '0')}, read 0x${read[i].toRadixString(16).padLeft(2, '0')}',
        );
      }
    }
    done += chunkLen;
    progress?.call(done, total);
  }
}
