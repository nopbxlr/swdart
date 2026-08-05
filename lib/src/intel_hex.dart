// Minimal Intel HEX parser producing a single contiguous image, so a .hex file
// can be flashed directly: `probe.program(img.base, img.data)`.
import 'dart:typed_data';

import 'util.dart';

/// A contiguous block of bytes with its target base address.
class FlashImage {
  FlashImage(this.base, this.data);

  /// Address of the first byte.
  final int base;

  /// The contiguous bytes (gaps between records are filled with 0xFF).
  final Uint8List data;
}

const _maxGapFill = 0x10000; // fill gaps up to 64 KB with 0xFF
const _maxImage = 0x200000; // 2 MB sanity cap

/// Parse Intel HEX [text] into one [FlashImage]. Throws [SwdException] on
/// malformed input, overlapping records, or an implausibly large gap/span.
FlashImage parseIntelHex(String text) {
  final segments = <_Segment>[];
  var upper = 0;
  _Segment? current;

  final lines = text.split(RegExp(r'\r?\n'));
  for (var ln = 0; ln < lines.length; ln++) {
    final line = lines[ln].trim();
    if (line.isEmpty) continue;
    if (!line.startsWith(':')) throw SwdException('HEX line ${ln + 1}: missing ":"');

    final bytes = <int>[];
    for (var i = 1; i + 1 < line.length; i += 2) {
      final b = int.tryParse(line.substring(i, i + 2), radix: 16);
      if (b == null) throw SwdException('HEX line ${ln + 1}: bad hex digits');
      bytes.add(b);
    }
    final count = bytes[0];
    if (bytes.length != count + 5) throw SwdException('HEX line ${ln + 1}: length mismatch');
    if (bytes.fold(0, (a, b) => (a + b) & 0xff) != 0) {
      throw SwdException('HEX line ${ln + 1}: checksum error');
    }

    final offset = (bytes[1] << 8) | bytes[2];
    final type = bytes[3];
    final payload = bytes.sublist(4, 4 + count);

    switch (type) {
      case 0x00: // data
        final address = upper + offset;
        if (current != null && current.address + current.data.length == address) {
          current.data.addAll(payload);
        } else {
          current = _Segment(address, [...payload]);
          segments.add(current);
        }
      case 0x01: // EOF
        return _build(segments);
      case 0x02: // extended segment address
        upper = ((payload[0] << 8) | payload[1]) << 4;
        current = null;
      case 0x04: // extended linear address
        upper = (((payload[0] << 8) | payload[1]) << 16) & 0xffffffff;
        current = null;
      case 0x03:
      case 0x05: // start-address records — irrelevant for flashing
        break;
      default:
        throw SwdException('HEX line ${ln + 1}: unsupported record type 0x${type.toRadixString(16)}');
    }
  }
  return _build(segments);
}

class _Segment {
  _Segment(this.address, this.data);
  final int address;
  final List<int> data;
}

FlashImage _build(List<_Segment> segments) {
  if (segments.isEmpty) throw SwdException('HEX file contains no data records');
  segments.sort((a, b) => a.address - b.address);

  final base = segments.first.address;
  final last = segments.last;
  final span = last.address + last.data.length - base;
  if (span > _maxImage) throw SwdException('HEX image span too large ($span bytes)');

  final data = Uint8List(span)..fillRange(0, span, 0xff);
  var prevEnd = base;
  for (final seg in segments) {
    if (seg.address < prevEnd) {
      throw SwdException('overlapping HEX segments at 0x${seg.address.toRadixString(16)}');
    }
    if (seg.address - prevEnd > _maxGapFill) {
      throw SwdException('gap of ${seg.address - prevEnd} bytes between HEX segments — split the image');
    }
    data.setRange(seg.address - base, seg.address - base + seg.data.length, seg.data);
    prevEnd = seg.address + seg.data.length;
  }
  return FlashImage(base, data);
}
