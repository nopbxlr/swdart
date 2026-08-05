// A small end-to-end demo: connect, inspect, and optionally flash a target.
//
//   dart run example/swdart_example.dart [firmware.bin]
//
// Needs an ST-Link and a target attached, and libusb-1.0 available (see README).
import 'dart:io';
import 'dart:typed_data';

import 'package:swdart/swdart.dart';

Future<void> main(List<String> args) async {
  final probe = Probe()..onLog((line) => stderr.writeln(line));

  // "under reset" is a good default: it catches the core at the reset vector,
  // even for firmware that reconfigures or disables the SWD pins once it runs.
  final target = await probe.connect(ConnectMode.underReset);
  stdout.writeln('Connected: ${target.name}  '
      '(IDCODE ${hex(target.idcode)}, ${target.flashKB} KB flash)');

  // --- debug: halt and dump core registers + the reset vector ---
  await probe.halt();
  for (final r in await probe.readRegisters()) {
    stdout.writeln('  ${r.name.padRight(4)} = ${hex(r.value)}');
  }
  final vectors = await probe.readMemory(0x08000000, 8);
  stdout.writeln('  initial SP/PC = ${hex(_u32(vectors, 0))} / ${hex(_u32(vectors, 4))}');

  // --- read protection state ---
  final prot = await probe.readProtection();
  stdout.writeln('Protection: ${prot.enabled ? 'ENABLED (${prot.level})' : 'disabled'}');

  // --- optionally flash a firmware image ---
  if (args.isNotEmpty) {
    final bytes = await File(args.first).readAsBytes();
    stdout.writeln('Flashing ${args.first} (${bytes.length} bytes)…');
    await probe.program(0x08000000, bytes); // reset-halt + erase + write + verify
    await probe.resetRun();
    stdout.writeln('Done — target reset and running.');
  }

  await probe.disconnect();
}

int _u32(Uint8List b, int o) => b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24;
