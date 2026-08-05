// Target identification: STM32F0/F1/F3 (and GD32 clones) via the shared FPEC,
// and Artery AT32 via its DBGMCU "project ID".
import 'cortexm.dart';
import 'stlink.dart';

// STM32F1 (Cortex-M3) exposes DBGMCU_IDCODE here; the flash-size word lives at
// 0x1FFFF7E0. STM32F0/F3 (Cortex-M0/M4) use 0x40015800 / 0x1FFFF7CC instead.
const _dbgmcuF1 = 0xe0042000;
const _dbgmcuF0F3 = 0x40015800;
const _flashSizeF1 = 0x1ffff7e0;
const _flashSizeF0F3 = 0x1ffff7cc;

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
  });

  /// Human-readable device name.
  final String name;

  /// Driver family: 'STM32' (FPEC), 'AT32' (FMC), or 'unknown'.
  final String family;

  /// DBGMCU IDCODE / Artery PID as read.
  final int idcode;

  /// Flash size in KB (0 if it could not be read).
  final int flashKB;

  /// Erase page/sector size in bytes.
  final int pageSize;

  /// On-chip SRAM in bytes (conservative minimum — sizes the SRAM flash loader).
  final int sramBytes;

  /// Flash base address (0x08000000).
  final int flashBase;

  /// Program granularity: 2 (STM32 halfword) or 4 (AT32 word).
  final int programAlign;

  /// Read-protection scheme: 'RDP', 'FAP', or 'none'.
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
  0x410: (name: 'STM32F1 medium-density', pageSize: 1024, sram: 10 * 1024, rdp: 0xa5, tested: true),
  0x414: (name: 'STM32F1 high-density', pageSize: 2048, sram: 48 * 1024, rdp: 0xa5, tested: true),
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

Future<int> _readReg(Stlink probe, int address) async {
  try {
    return await probe.readDebugReg(address);
  } catch (_) {
    return 0;
  }
}

Future<int> _readFlashKB(Stlink probe, int reg) async {
  final kb = await _readReg(probe, reg) & 0xffff;
  return kb == 0xffff ? 0 : kb;
}

Future<TargetInfo> detectTarget(Stlink probe, CortexM core) async {
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
        family: 'AT32',
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
      family: 'AT32',
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
    family: 'unknown',
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

Future<TargetInfo> _stm32(Stlink probe, int idcode, _Stm dev, int flashSizeReg) async {
  final flashKB = await _readFlashKB(probe, flashSizeReg);
  return TargetInfo(
    name: '${dev.name}${flashKB > 0 ? ', $flashKB KB flash' : ''}',
    family: 'STM32',
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
