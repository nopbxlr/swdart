// SRAM flash-programming loaders (ported from openocd-ts src/flash/loader.ts).
//
// The ST-Link bulk memory commands only do 8/32-bit accesses, but the flash
// controllers need a specific program width (16-bit halfwords on STM32F1,
// 32-bit words on AT32). A tiny hand-assembled Thumb routine in target SRAM
// copies a buffer into flash one unit at a time, polling the busy flag, then
// hits BKPT. Register contract:
//   r0 = source (SRAM buffer), r1 = destination (flash),
//   r2 = unit count,           r3 = flash register base (0x40022000)
// Leaves r2 == 0 on success; polls busy on bit0 of [r3, #0x0C]; error mask
// bit2|bit4 (0x14). Every instruction and branch offset was verified.
import 'dart:typed_data';

import 'cortexm.dart';
import 'debug_probe.dart';
import 'stlink.dart';
import 'util.dart';

const halfwordLoader = <int>[
  0x2a00, 0xd00c, 0x8804, 0x800c, 0x68dd, 0x2601, 0x4235, 0xd1fb,
  0x2614, 0x4235, 0xd104, 0x3002, 0x3102, 0x3a01, 0xe7f0, 0xbe00, 0xbe01,
];

const wordLoader = <int>[
  0x2a00, 0xd00c, 0x6804, 0x600c, 0x68dd, 0x2601, 0x4235, 0xd1fb,
  0x2614, 0x4235, 0xd104, 0x3004, 0x3104, 0x3a01, 0xe7f0, 0xbe00, 0xbe01,
];

const _flashRegBase = 0x40022000;

Uint8List _loaderToBytes(List<int> code) {
  final bytes = Uint8List(((code.length * 2 + 3) >> 2) << 2);
  for (var i = 0; i < code.length; i++) {
    bytes[i * 2] = code[i] & 0xff;
    bytes[i * 2 + 1] = code[i] >> 8;
  }
  return bytes;
}

/// Upload [code] to [loaderAddr], run once with the register contract, and wait
/// for BKPT. Throws if it stopped early (r2 != 0 -> programming error). The
/// caller sets the flash controller into program mode before calling and reads
/// the status register afterwards.
Future<void> runLoader(
  DebugProbe probe,
  CortexM core,
  List<int> code, {
  required int loaderAddr,
  required int srcAddr,
  required int dstAddr,
  required int count,
}) async {
  await probe.writeMem32(loaderAddr, _loaderToBytes(code));

  await probe.writeReg(regR0, srcAddr);
  await probe.writeReg(regR1, dstAddr);
  await probe.writeReg(regR2, count);
  await probe.writeReg(regR3, _flashRegBase);
  await probe.writeReg(regSp, srcAddr); // stackless; kept sane
  await probe.writeReg(regPc, loaderAddr);
  await probe.writeReg(regXpsr, 0x01000000); // Thumb bit

  await core.resume();
  await core.waitHalted(10000);

  final remaining = await probe.readReg(regR2);
  if (remaining != 0) {
    throw SwdException(
      'flash loader stopped early at ${hex(dstAddr)} ($remaining units left) — programming error',
    );
  }
}
