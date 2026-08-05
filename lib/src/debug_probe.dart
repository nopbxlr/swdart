// The hardware-agnostic debug-probe contract.
//
// Everything above the wire — Cortex-M debug control, target detection, the
// flash drivers and CTRL-AP recovery — drives the target through this surface,
// not through any one probe's protocol. [Stlink] is the implementation today; a
// CMSIS-DAP or J-Link backend would implement the same interface (most of the
// real work for those is a host-side ADIv5 MEM-AP layer feeding these methods).
import 'dart:typed_data';

/// Probe firmware / version info.
class ProbeVersion {
  ProbeVersion(this.stlink, this.jtag, this.swim, this.text);
  final int stlink;
  final int jtag;
  final int swim;
  final String text;
}

/// A SWD debug probe attached to one Cortex-M target.
abstract class DebugProbe {
  /// Probe firmware / version info.
  ProbeVersion get version;

  /// Human-readable probe name, e.g. "ST-Link/V2".
  String get probeName;

  /// Native 16-bit memory access is available.
  bool get hasMem16;

  /// Raw DAP-register access ([readDapReg]/[writeDapReg]) is available.
  bool get hasDapReg;

  /// Multi-AP open/close ([initAp]) is available — needed to reach any AP other
  /// than the AHB-AP (e.g. Nordic's CTRL-AP).
  bool get hasApInit;

  /// Prepare the probe for use (firmware handshake, leave DFU, etc.).
  Future<void> init();

  /// Enter SWD debug mode.
  Future<void> enterSwd();

  /// Read the SW-DP IDCODE.
  Future<int> readIdcode();

  /// Target supply voltage in volts, or null if the probe can't measure it.
  Future<double?> getTargetVoltage();

  /// Issue a system reset to the target.
  Future<void> resetSys();

  /// Drive nRST: 0 = low (assert), 1 = high (release), 2 = pulse.
  Future<void> driveNrst(int state);

  /// Read a core register by index.
  Future<int> readReg(int index);

  /// Write a core register by index.
  Future<void> writeReg(int index, int value);

  /// Read a 32-bit word from memory / a memory-mapped debug register (AHB-AP).
  Future<int> readDebugReg(int address);

  /// Write a 32-bit word to memory / a memory-mapped debug register (AHB-AP).
  Future<void> writeDebugReg(int address, int value);

  /// Open (initialize) access port [apSel] so its registers can be reached.
  Future<void> initAp(int apSel);

  /// Close access port [apSel].
  Future<void> closeAp(int apSel);

  /// Read raw DAP register [addr] on access port [apSel].
  Future<int> readDapReg(int apSel, int addr);

  /// Write raw DAP register [addr] on access port [apSel].
  Future<void> writeDapReg(int apSel, int addr, int value);

  /// Block read of 32-bit-aligned memory.
  Future<Uint8List> readMem32(int address, int length);

  /// Block write of 32-bit-aligned memory.
  Future<void> writeMem32(int address, Uint8List data);

  /// Byte read of memory (unaligned / small transfers).
  Future<Uint8List> readMem8(int address, int length);

  /// Byte write of memory (unaligned / small transfers).
  Future<void> writeMem8(int address, Uint8List data);

  /// 16-bit memory write (needs [hasMem16]).
  Future<void> writeU16(int address, int value);

  /// 16-bit memory read (needs [hasMem16]).
  Future<int> readU16(int address);

  /// Release the target and close the probe.
  Future<void> close();
}
