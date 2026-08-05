// Target identification: STM32F0/F1/F3 (and GD32 clones) via the shared FPEC,
// Artery AT32 via its DBGMCU "project ID", and Nordic nRF51/nRF52 via FICR.
import 'cortexm.dart';
import 'debug_probe.dart';

// STM32F1 (Cortex-M3) exposes DBGMCU_IDCODE here; the flash-size word lives at
// 0x1FFFF7E0. STM32F0/F3 (Cortex-M0/M4) use 0x40015800 / 0x1FFFF7CC instead.
const _dbgmcuF1 = 0xe0042000;
const _dbgmcuF0F3 = 0x40015800;
const _flashSizeF1 = 0x1ffff7e0;
const _flashSizeF0F3 = 0x1ffff7cc;

/// Which flash-driver family a detected target maps to.
enum TargetFamily {
  /// ST FPEC — STM32F0/F1/F3 and GigaDevice GD32F103/GD32E103.
  stm32,

  /// Artery FMC (AT32F415).
  at32,

  /// Nordic NVMC (nRF51/nRF52).
  nrf,

  /// Detected but unsupported / unidentified.
  unknown,
}

class TargetInfo {
  TargetInfo({
    required this.name,
    required this.family,
    required this.idcode,
    required this.flashKB,
    required this.pageSize,
    required this.sramBytes,
    required this.flashBase,
    required this.programAlign,
    required this.protection,
    required this.rdpDisableValue,
    required this.tested,
    this.word = false,
  });

  /// Human-readable device name.
  final String name;

  /// Which flash-driver family this target maps to.
  final TargetFamily family;

  /// For [TargetFamily.stm32]: true if the FPEC programs in 32-bit words
  /// (GD32E103) rather than 16-bit halfwords. Selects the loader/option width.
  final bool word;

  /// DBGMCU IDCODE / Artery PID as read.
  final int idcode;

  /// Flash size in KB (0 if it could not be read).
  final int flashKB;

  /// Erase page/sector size in bytes.
  final int pageSize;

  /// On-chip SRAM in bytes (conservative minimum — sizes the SRAM flash loader).
  final int sramBytes;

  /// Flash base address (0x08000000 on STM32/AT32, 0x00000000 on Nordic).
  final int flashBase;

  /// Program granularity: 2 (STM32 halfword) or 4 (AT32/Nordic word).
  final int programAlign;

  /// Read-protection scheme: 'RDP', 'FAP', 'APPROTECT', 'RBPCONF', or 'none'.
  final String protection;

  /// Value that disables read protection (STM32: 0xA5 on F1, 0xAA on F0/F3).
  final int rdpDisableValue;

  /// True if this exact device has been verified on real hardware.
  final bool tested;
}

// ── STM32 device tables (device_id in DBGMCU IDCODE bits [11:0]) ──────────────
typedef _Stm = ({String name, int pageSize, int sram, int rdp, bool tested});

// F1 line — DBGMCU at 0xE0042000, flash size at 0x1FFFF7E0, RDP disable 0xA5.
const _stm32f1 = <int, _Stm>{
  0x412: (name: 'STM32F1 low-density', pageSize: 1024, sram: 6 * 1024, rdp: 0xa5, tested: false),
  0x410: (name: 'STM32F103 / GD32F103 medium-density', pageSize: 1024, sram: 10 * 1024, rdp: 0xa5, tested: true),
  0x414: (name: 'STM32F103 / GD32F30x high-density', pageSize: 2048, sram: 48 * 1024, rdp: 0xa5, tested: true),
  0x418: (name: 'STM32F105/107 connectivity', pageSize: 2048, sram: 32 * 1024, rdp: 0xa5, tested: false),
  0x430: (name: 'STM32F1 XL-density', pageSize: 2048, sram: 80 * 1024, rdp: 0xa5, tested: false),
  0x420: (name: 'STM32F100 value (low/medium)', pageSize: 1024, sram: 4 * 1024, rdp: 0xa5, tested: false),
  0x428: (name: 'STM32F100 value (high)', pageSize: 2048, sram: 24 * 1024, rdp: 0xa5, tested: false),
};

// F0/F3 lines — DBGMCU at 0x40015800, flash size at 0x1FFFF7CC, RDP disable 0xAA.
const _stm32f0f3 = <int, _Stm>{
  0x444: (name: 'STM32F03x', pageSize: 1024, sram: 4 * 1024, rdp: 0xaa, tested: false),
  0x445: (name: 'STM32F04x', pageSize: 1024, sram: 6 * 1024, rdp: 0xaa, tested: false),
  0x440: (name: 'STM32F05x', pageSize: 1024, sram: 8 * 1024, rdp: 0xaa, tested: false),
  0x448: (name: 'STM32F07x', pageSize: 2048, sram: 16 * 1024, rdp: 0xaa, tested: false),
  0x442: (name: 'STM32F09x', pageSize: 2048, sram: 32 * 1024, rdp: 0xaa, tested: false),
  0x422: (name: 'STM32F302/303 xB/xC', pageSize: 2048, sram: 16 * 1024, rdp: 0xaa, tested: false),
  0x446: (name: 'STM32F303 xD/xE', pageSize: 2048, sram: 64 * 1024, rdp: 0xaa, tested: false),
  0x432: (name: 'STM32F37x', pageSize: 2048, sram: 16 * 1024, rdp: 0xaa, tested: false),
  0x438: (name: 'STM32F33x', pageSize: 2048, sram: 12 * 1024, rdp: 0xaa, tested: false),
  0x439: (name: 'STM32F302x6/8', pageSize: 2048, sram: 16 * 1024, rdp: 0xaa, tested: false),
};

// ── Artery AT32 (DBGMCU IDCODE == Artery "project ID") ───────────────────────
class _ArteryPart {
  const _ArteryPart(this.pid, this.name, this.flashKB, this.pageSize);
  final int pid;
  final String name;
  final int flashKB;
  final int pageSize;
}

const _at32f415 = <_ArteryPart>[
  _ArteryPart(0x70030240, 'AT32F415RCT7', 256, 2048),
  _ArteryPart(0x70030241, 'AT32F415CCT7', 256, 2048),
  _ArteryPart(0x70030242, 'AT32F415KCU7-4', 256, 2048),
  _ArteryPart(0x70030243, 'AT32F415RCT7-7', 256, 2048),
  _ArteryPart(0x7003024c, 'AT32F415CCU7', 256, 2048),
  _ArteryPart(0x700301c4, 'AT32F415RBT7', 128, 1024),
  _ArteryPart(0x700301c5, 'AT32F415CBT7', 128, 1024),
  _ArteryPart(0x700301c6, 'AT32F415KBU7-4', 128, 1024),
  _ArteryPart(0x700301c7, 'AT32F415RBT7-7', 128, 1024),
  _ArteryPart(0x700301cd, 'AT32F415CBU7', 128, 1024),
  _ArteryPart(0x70030108, 'AT32F415R8T7', 64, 1024),
  _ArteryPart(0x70030109, 'AT32F415C8T7', 64, 1024),
  _ArteryPart(0x7003010a, 'AT32F415K8U7-4', 64, 1024),
];

// PIDs shared between AT32F413 (has FPU) and AT32F415 (no FPU).
const _collidingPids = <int>{0x700301c5, 0x70030240, 0x70030242};

Future<int> _readReg(DebugProbe probe, int address) async {
  try {
    return await probe.readDebugReg(address);
  } catch (_) {
    return 0;
  }
}

Future<int> _readFlashKB(DebugProbe probe, int reg) async {
  final kb = await _readReg(probe, reg) & 0xffff;
  return kb == 0xffff ? 0 : kb;
}

// ── Nordic nRF51 / nRF52 (FICR at 0x10000000) ────────────────────────────────
const _ficrCodePageSize = 0x10000010; // bytes per page (1024 nRF51, 4096 nRF52)
const _ficrCodeSize = 0x10000014; //     flash size in pages
const _ficrInfoPart = 0x10000100; //     part number (nRF52+; 0xFFFFFFFF on nRF51)

/// Positive Nordic signature: a sane FICR page size + page count. STM32/AT32
/// read 0 (reserved region) here, so this can run first without false matches.
Future<TargetInfo?> _detectNordic(DebugProbe probe) async {
  final pageSize = await _readReg(probe, _ficrCodePageSize);
  final codePages = await _readReg(probe, _ficrCodeSize);
  final pageOk = pageSize == 1024 || pageSize == 2048 || pageSize == 4096;
  if (!pageOk || codePages == 0 || codePages > 0x1000) return null;

  final flashKB = (pageSize * codePages) ~/ 1024;
  final isNrf52 = pageSize >= 4096;
  final part = await _readReg(probe, _ficrInfoPart);
  final hasPart = part != 0 && part != 0xffffffff;
  return TargetInfo(
    name: hasPart
        ? 'nRF${part.toRadixString(16)} ($flashKB KB, $pageSize B pages)'
        : '${isNrf52 ? 'nRF52' : 'nRF51'} series ($flashKB KB, $pageSize B pages)',
    family: TargetFamily.nrf,
    idcode: hasPart ? part : 0,
    flashKB: flashKB,
    pageSize: pageSize,
    sramBytes: 16 * 1024, // unused: the NVMC driver needs no SRAM loader
    flashBase: 0x00000000,
    programAlign: 4,
    protection: isNrf52 ? 'APPROTECT' : 'RBPCONF',
    rdpDisableValue: 0,
    tested: false,
  );
}

// GigaDevice FMC product-ID register (0x40022000 + 0x100). GD32 parts return a
// signature here that STM32 (no such register), AT32 and Nordic do not.
// Reverse-engineered from a GD flasher firmware that supports all three chips.
const _gd32FmcPid = 0x40022100;
const _gd32e103Pid = 0x48424333; // GD32E103 — Cortex-M4, 32-bit WORD flash
// (GD32F103's FMC_PID is 0x41424333, but it's 16-bit like STM32 and already
// matches device id 0x410/0x414, so it needs no special-case here.)

Future<TargetInfo> detectTarget(DebugProbe probe, CortexM core) async {
  // Nordic first — its FICR signature is unambiguous and avoids an nRF whose
  // 0xE0042000 read happens to look AT32-like.
  final nrf = await _detectNordic(probe);
  if (nrf != null) return nrf;

  // GD32E103 must be caught by its FMC_PID before the STM32F1 device-id table:
  // it may share device id 0x410 with medium-density parts, yet it programs in
  // 32-bit words (word: true), not halfwords.
  if (await _readReg(probe, _gd32FmcPid) == _gd32e103Pid) {
    final kb = (await _readFlashKB(probe, _flashSizeF1)).clamp(0, 4096);
    return TargetInfo(
      name: 'GD32E103 (Cortex-M4${kb > 0 ? ', $kb KB' : ''}, word-programmed FPEC)',
      family: TargetFamily.stm32,
      word: true,
      idcode: _gd32e103Pid,
      flashKB: kb == 0 ? 128 : kb,
      pageSize: 1024,
      sramBytes: 32 * 1024,
      flashBase: 0x08000000,
      programAlign: 4,
      protection: 'RDP',
      rdpDisableValue: 0xa5,
      tested: false,
    );
  }

  final idcode1 = await _readReg(probe, _dbgmcuF1);

  // Artery AT32 — the PID is the DBGMCU IDCODE (top byte 0x70/0x50).
  if ((idcode1 >> 24) == 0x70 || (idcode1 >> 24) == 0x50) {
    var matches = _at32f415.where((p) => p.pid == idcode1).toList();
    if (matches.isNotEmpty && _collidingPids.contains(idcode1)) {
      if (await core.hasFpu()) matches = []; // FPU present => F413, not handled
    }
    if (matches.isNotEmpty) {
      final p = matches.first;
      return TargetInfo(
        name: '${p.name} (${p.flashKB} KB, ${p.pageSize} B pages)',
        family: TargetFamily.at32,
        idcode: idcode1,
        flashKB: p.flashKB,
        pageSize: p.pageSize,
        sramBytes: 32 * 1024,
        flashBase: 0x08000000,
        programAlign: 4,
        protection: 'FAP',
        rdpDisableValue: 0xa5,
        tested: true,
      );
    }
    final flashKB = (await _readFlashKB(probe, _flashSizeF1)).clamp(0, 4096);
    final kb = flashKB == 0 ? 128 : flashKB;
    return TargetInfo(
      name: 'Artery AT32 device 0x${idcode1.toRadixString(16)} (untested — F415-like assumed)',
      family: TargetFamily.at32,
      idcode: idcode1,
      flashKB: kb,
      pageSize: kb > 128 ? 2048 : 1024,
      sramBytes: 32 * 1024,
      flashBase: 0x08000000,
      programAlign: 4,
      protection: 'FAP',
      rdpDisableValue: 0xa5,
      tested: false,
    );
  }

  // STM32F1 (Cortex-M3) — device_id at 0xE0042000.
  final f1 = _stm32f1[idcode1 & 0xfff];
  if (f1 != null) {
    return _stm32(probe, idcode1, f1, _flashSizeF1);
  }

  // STM32F0/F3 (Cortex-M0/M4) — device_id at 0x40015800.
  final idcode2 = await _readReg(probe, _dbgmcuF0F3);
  final f03 = _stm32f0f3[idcode2 & 0xfff];
  if (f03 != null) {
    return _stm32(probe, idcode2, f03, _flashSizeF0F3);
  }

  final shown = idcode1 != 0 ? idcode1 : idcode2;
  return TargetInfo(
    name: shown == 0
        ? 'unknown (IDCODE reads 0 — target under reset or no SWD?)'
        : 'unknown device (IDCODE 0x${shown.toRadixString(16)})',
    family: TargetFamily.unknown,
    idcode: shown,
    flashKB: 0,
    pageSize: 1024,
    sramBytes: 8 * 1024,
    flashBase: 0x08000000,
    programAlign: 2,
    protection: 'none',
    rdpDisableValue: 0xa5,
    tested: false,
  );
}

Future<TargetInfo> _stm32(DebugProbe probe, int idcode, _Stm dev, int flashSizeReg) async {
  final flashKB = await _readFlashKB(probe, flashSizeReg);
  return TargetInfo(
    name: '${dev.name}${flashKB > 0 ? ', $flashKB KB flash' : ''}',
    family: TargetFamily.stm32,
    idcode: idcode,
    flashKB: flashKB,
    pageSize: dev.pageSize,
    sramBytes: dev.sram,
    flashBase: 0x08000000,
    programAlign: 2,
    protection: 'RDP',
    rdpDisableValue: dev.rdp,
    tested: dev.tested,
  );
}
