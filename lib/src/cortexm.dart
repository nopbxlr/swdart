// Cortex-M debug control on top of an ST-Link probe (ported from openocd-ts
// src/core/cortexm.ts). Standard ARMv7-M debug registers.
import 'stlink.dart';
import 'util.dart';

const dhcsr = 0xe000edf0;
const demcr = 0xe000edfc;
const aircr = 0xe000ed0c;

const _dbgkey = 0xa05f0000;
const _cDebugen = 1 << 0;
const _cHalt = 1 << 1;
const _cStep = 1 << 2;
const _sHalt = 1 << 17;

const _vcCorereset = 1 << 0;
const _aircrSysresetreq = 0x05fa0004;

class CortexM {
  CortexM(this._probe);
  final Stlink _probe;

  Future<bool> isHalted() async => (await _probe.readDebugReg(dhcsr) & _sHalt) != 0;

  Future<void> halt() => _probe.writeDebugReg(dhcsr, _dbgkey | _cDebugen | _cHalt);

  Future<void> resume() => _probe.writeDebugReg(dhcsr, _dbgkey | _cDebugen);

  Future<void> step() async {
    await _probe.writeDebugReg(dhcsr, _dbgkey | _cDebugen | _cHalt);
    await _probe.writeDebugReg(dhcsr, _dbgkey | _cDebugen | _cStep);
  }

  Future<void> waitHalted([int timeoutMs = 3000]) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(deadline)) {
      if (await isHalted()) return;
      await sleep(5);
    }
    throw SwdException('core did not halt within $timeoutMs ms');
  }

  /// Reset the MCU and catch it halted at the reset vector.
  Future<void> resetHalt() async {
    await halt();
    await _probe.writeDebugReg(demcr, _vcCorereset);
    await _probe.resetSys();
    await waitHalted();
    await _probe.writeDebugReg(demcr, 0);
  }

  /// Reset the MCU and let it run free.
  Future<void> resetRun() async {
    await _probe.writeDebugReg(demcr, 0);
    await _probe.writeDebugReg(dhcsr, _dbgkey | _cDebugen);
    await _probe.writeDebugReg(aircr, _aircrSysresetreq);
  }

  Future<List<({String name, int value})>> readAllRegs() async {
    const names = [
      'r0', 'r1', 'r2', 'r3', 'r4', 'r5', 'r6', 'r7',
      'r8', 'r9', 'r10', 'r11', 'r12', 'sp', 'lr', 'pc', 'xpsr',
    ];
    final out = <({String name, int value})>[];
    for (var i = 0; i < names.length; i++) {
      out.add((name: names[i], value: await _probe.readReg(i)));
    }
    return out;
  }

  Future<int> readPc() => _probe.readReg(regPc);

  /// FP unit present? MVFR0 (0xE000EF34) reads 0 without the FP extension.
  /// Used to tell AT32F413 (has FPU) from AT32F415 (none) on shared IDCODEs.
  Future<bool> hasFpu() async => (await _probe.readDebugReg(0xe000ef34)) != 0;
}
