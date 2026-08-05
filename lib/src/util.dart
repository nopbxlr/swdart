// Small helpers shared across the Dart ST-Link stack (ported from openocd-ts
// src/lib/util.ts).
import 'dart:typed_data';

String hex(int value, [int width = 8]) =>
    '0x${(value & 0xFFFFFFFF).toRadixString(16).toUpperCase().padLeft(width, '0')}';

Future<void> sleep(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

int u32le(Uint8List b, int o) =>
    (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) & 0xFFFFFFFF;

/// Little-endian byte lists for building command packets.
List<int> u32(int v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

List<int> u16(int v) => [v & 0xff, (v >> 8) & 0xff];

class SwdException implements Exception {
  SwdException(this.message);
  final String message;
  @override
  String toString() => message;
}
