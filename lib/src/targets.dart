// Target identification (ported from openocd-ts src/targets.ts).
import 'cortexm.dart';
import 'stlink.dart';

const _dbgmcuIdcode = 0xe0042000;
const _flashSizeReg = 0x1ffff7e0;

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
    required this.tested,
  });
  final String name;
  final String family; // 'STM32F1' | 'AT32' | 'unknown'
  final int idcode;
  final int flashKB;
  final int pageSize;
  final int sramBytes;
  final int flashBase;
  final int programAlign;
  final String protection; // 'RDP' | 'FAP' | 'none'
  final bool tested;
}

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

const _collidingPids = <int>{0x700301c5, 0x70030240, 0x70030242};

const _stm32f1 = <int, ({String name, int sram})>{
  0x412: (name: 'STM32F103 (low density)', sram: 10 * 1024),
  0x410: (name: 'STM32F103 (medium density)', sram: 20 * 1024),
  0x414: (name: 'STM32F103 (high density)', sram: 64 * 1024),
  0x418: (name: 'STM32F105/F107 (connectivity)', sram: 64 * 1024),
  0x430: (name: 'STM32F103 (XL density)', sram: 96 * 1024),
};

Future<int> _readFlashKB(Stlink probe) async {
  try {
    final kb = await probe.readDebugReg(_flashSizeReg) & 0xffff;
    return kb == 0xffff ? 0 : kb;
  } catch (_) {
    return 0;
  }
}

Future<TargetInfo> detectTarget(Stlink probe, CortexM core) async {
  final idcode = await probe.readDebugReg(_dbgmcuIdcode);

  if ((idcode >> 24) == 0x70 || (idcode >> 24) == 0x50) {
    var matches = _at32f415.where((p) => p.pid == idcode).toList();
    if (matches.isNotEmpty && _collidingPids.contains(idcode)) {
      if (await core.hasFpu()) matches = []; // FPU => F413, not handled here
    }
    if (matches.isNotEmpty) {
      final p = matches.first;
      return TargetInfo(
        name: '${p.name} (${p.flashKB} KB, ${p.pageSize} B pages)',
        family: 'AT32',
        idcode: idcode,
        flashKB: p.flashKB,
        pageSize: p.pageSize,
        sramBytes: 32 * 1024,
        flashBase: 0x08000000,
        programAlign: 4,
        protection: 'FAP',
        tested: true,
      );
    }
    final probedKB = await _readFlashKB(probe);
    final flashKB = probedKB == 0 ? 128 : probedKB;
    return TargetInfo(
      name: 'Artery AT32 device ${idcode.toRadixString(16)} (untested — F415-like assumed)',
      family: 'AT32',
      idcode: idcode,
      flashKB: flashKB,
      pageSize: flashKB > 128 ? 2048 : 1024,
      sramBytes: 32 * 1024,
      flashBase: 0x08000000,
      programAlign: 4,
      protection: 'FAP',
      tested: false,
    );
  }

  final dev = idcode & 0xfff;
  final known = _stm32f1[dev];
  if (known != null) {
    final flashKB = await _readFlashKB(probe);
    return TargetInfo(
      name: '${known.name}, ${flashKB == 0 ? "?" : flashKB} KB flash',
      family: 'STM32F1',
      idcode: idcode,
      flashKB: flashKB,
      pageSize: flashKB > 128 ? 2048 : 1024,
      sramBytes: known.sram,
      flashBase: 0x08000000,
      programAlign: 2,
      protection: 'RDP',
      tested: dev == 0x410 || dev == 0x414,
    );
  }

  return TargetInfo(
    name: idcode == 0
        ? 'unknown (IDCODE reads 0 — target under reset or no SWD?)'
        : 'unknown device (IDCODE ${idcode.toRadixString(16)})',
    family: 'unknown',
    idcode: idcode,
    flashKB: 0,
    pageSize: 1024,
    sramBytes: 10 * 1024,
    flashBase: 0x08000000,
    programAlign: 2,
    protection: 'none',
    tested: false,
  );
}
