import 'dart:typed_data';

import 'package:swdart/swdart.dart';
import 'package:swdart/src/loader.dart';
import 'package:swdart/src/util.dart';
import 'package:test/test.dart';

void main() {
  group('util', () {
    test('hex formats 32-bit values', () {
      expect(hex(0x08000000), '0x08000000');
      expect(hex(0xdeadbeef), '0xDEADBEEF');
      expect(hex(0x1f, 4), '0x001F');
    });
    test('u32le / little-endian byte lists', () {
      expect(u32le(Uint8List.fromList([0x78, 0x56, 0x34, 0x12]), 0), 0x12345678);
      expect(u32(0x12345678), [0x78, 0x56, 0x34, 0x12]);
      expect(u16(0xbeef), [0xef, 0xbe]);
    });
  });

  group('Thumb flash loaders', () {
    test('are 17 halfwords each', () {
      expect(halfwordLoader.length, 17);
      expect(wordLoader.length, 17);
    });
    test('differ only in load/store width and pointer stride', () {
      // Same control flow; only indices 2,3 (ldrh/strh vs ldr/str) and 11,12
      // (adds #2 vs #4) may differ.
      const mayDiffer = {2, 3, 11, 12};
      for (var i = 0; i < 17; i++) {
        if (mayDiffer.contains(i)) continue;
        expect(wordLoader[i], halfwordLoader[i], reason: 'index $i must match');
      }
      expect(halfwordLoader[2], 0x8804); // ldrh r4,[r0]
      expect(wordLoader[2], 0x6804); //     ldr  r4,[r0]
      expect(halfwordLoader[11], 0x3002); // adds r0,#2
      expect(wordLoader[11], 0x3004); //     adds r0,#4
      expect(halfwordLoader.last, 0xbe01); // bkpt #1 (error)
    });
  });

  group('Intel HEX', () {
    test('parses a simple record set', () {
      // 8 bytes at offset 0, then EOF.
      const hexText = ':080000000102030405060708D4\n'
          ':00000001FF\n';
      final img = parseIntelHex(hexText);
      expect(img.base, 0);
      expect(img.data, [1, 2, 3, 4, 5, 6, 7, 8]);
    });
    test('honours extended linear addresses', () {
      const hexText = ':020000040800F2\n' // upper = 0x0800_0000
          ':04000000AABBCCDDEE\n'
          ':00000001FF\n';
      final img = parseIntelHex(hexText);
      expect(img.base, 0x08000000);
      expect(img.data, [0xAA, 0xBB, 0xCC, 0xDD]);
    });
    test('rejects a bad checksum', () {
      expect(() => parseIntelHex(':0800000001020304050607080B\n'), throwsA(isA<SwdException>()));
    });
  });

  group('target detection', () {
    test('STM32F1 medium-density at 0xE0042000', () async {
      final probe = Stlink(_FakeTransport({
        0xe0042000: 0x20036410, // rev|dev 0x410
        0x1ffff7e0: 64, // 64 KB
        0xe000ef34: 0, // no FPU
      }));
      final t = await detectTarget(probe, CortexM(probe));
      expect(t.family, 'STM32');
      expect(t.pageSize, 1024);
      expect(t.rdpDisableValue, 0xa5);
      expect(t.flashKB, 64);
      expect(t.programAlign, 2);
    });

    test('STM32F03x via the F0/F3 IDCODE at 0x40015800 (RDP 0xAA)', () async {
      final probe = Stlink(_FakeTransport({
        0xe0042000: 0, // not an F1 / AT32
        0x40015800: 0x10006444, // dev 0x444
        0x1ffff7cc: 32,
        0xe000ef34: 0,
      }));
      final t = await detectTarget(probe, CortexM(probe));
      expect(t.family, 'STM32');
      expect(t.name, contains('F03'));
      expect(t.rdpDisableValue, 0xaa);
    });

    test('AT32F415CBT7 (no FPU disambiguates the shared PID)', () async {
      final probe = Stlink(_FakeTransport({
        0xe0042000: 0x700301c5,
        0xe000ef34: 0, // no FPU => F415, not F413
      }));
      final t = await detectTarget(probe, CortexM(probe));
      expect(t.family, 'AT32');
      expect(t.pageSize, 1024);
      expect(t.flashKB, 128);
      expect(t.programAlign, 4);
    });

    test('Nordic nRF52832 via FICR (4 KB pages, APPROTECT)', () async {
      final probe = Stlink(_FakeTransport({
        0x10000010: 4096, // FICR.CODEPAGESIZE
        0x10000014: 128, //  FICR.CODESIZE (pages) => 512 KB
        0x10000100: 0x52832, // FICR.INFO.PART
      }));
      final t = await detectTarget(probe, CortexM(probe));
      expect(t.family, 'NRF');
      expect(t.name, contains('nRF52832'));
      expect(t.pageSize, 4096);
      expect(t.flashKB, 512);
      expect(t.flashBase, 0);
      expect(t.programAlign, 4);
      expect(t.protection, 'APPROTECT');
    });

    test('Nordic nRF51 via FICR (1 KB pages, RBPCONF, no INFO.PART)', () async {
      final probe = Stlink(_FakeTransport({
        0x10000010: 1024, // FICR.CODEPAGESIZE
        0x10000014: 256, //  256 KB
        0x10000100: 0xffffffff, // INFO.PART unimplemented on nRF51
      }));
      final t = await detectTarget(probe, CortexM(probe));
      expect(t.family, 'NRF');
      expect(t.name, contains('nRF51'));
      expect(t.pageSize, 1024);
      expect(t.flashKB, 256);
      expect(t.protection, 'RBPCONF');
    });
  });

  group('Nordic CTRL-AP recovery', () {
    test('opens CTRL-AP, checks IDR, and issues ERASEALL', () async {
      final t = _DapTransport(idr: 0x02880000);
      final probe = Stlink(t)..version = ProbeVersion(2, 30, 0, 'V2J30');
      final res = await nrfCtrlApEraseAll(probe);
      expect(res.unprotected, isTrue);
      expect(t.log, containsAllInOrder([
        'initap:1', // open CTRL-AP (#1)
        'read:1:fc', // read IDR
        'write:1:0:1', // hold reset
        'write:1:4:1', // ERASEALL = 1
        'read:1:8', // poll ERASEALLSTATUS
        'write:1:0:0', // release reset
        'read:1:c', // APPROTECTSTATUS
      ]));
    });

    test('refuses to erase a non-Nordic CTRL-AP', () async {
      final t = _DapTransport(idr: 0xdeadbeef);
      final probe = Stlink(t)..version = ProbeVersion(2, 30, 0, 'V2J30');
      await expectLater(nrfCtrlApEraseAll(probe), throwsA(isA<SwdException>()));
      expect(t.log, isNot(contains('write:1:4:1'))); // never issued ERASEALL
    });

    test('rejects ST-Link firmware older than J28', () async {
      final t = _DapTransport(idr: 0x02880000);
      final probe = Stlink(t)..version = ProbeVersion(2, 24, 0, 'V2J24');
      await expectLater(nrfCtrlApEraseAll(probe), throwsA(isA<SwdException>()));
      expect(t.log, isEmpty); // bailed before touching the wire
    });
  });
}

/// Records CTRL-AP traffic and answers READ/WRITE_DAP_REG + INIT/CLOSE_AP so the
/// recovery sequence can be exercised without hardware.
class _DapTransport implements UsbTransport {
  _DapTransport({required this.idr});
  final int idr;
  final log = <String>[];

  @override
  int get productId => 0x3748;
  @override
  String get productName => 'fake';
  @override
  bool get isV3 => false;

  @override
  Future<Uint8List> xfer(List<int> command, {int rxLen = 0, Uint8List? data}) async {
    if (command.length >= 2 && command[0] == 0xf2) {
      switch (command[1]) {
        case 0x4b: // INIT_AP
          log.add('initap:${command[2]}');
          return Uint8List.fromList([0x80, 0]);
        case 0x4c: // CLOSE_AP
          log.add('closeap:${command[2]}');
          return Uint8List.fromList([0x80, 0]);
        case 0x45: // READ_DAP_REG
          final port = command[2] | command[3] << 8;
          final addr = command[4] | command[5] << 8;
          log.add('read:$port:${addr.toRadixString(16)}');
          final v = switch (addr) {
            0xfc => idr, // IDR
            0x08 => 0, //   ERASEALLSTATUS: done
            0x0c => 1, //   APPROTECTSTATUS: unprotected
            _ => 0,
          };
          return Uint8List.fromList([0x80, 0, 0, 0, v & 0xff, v >> 8 & 0xff, v >> 16 & 0xff, v >> 24 & 0xff]);
        case 0x46: // WRITE_DAP_REG
          final port = command[2] | command[3] << 8;
          final addr = command[4] | command[5] << 8;
          final val = command[6] | command[7] << 8 | command[8] << 16 | command[9] << 24;
          log.add('write:$port:${addr.toRadixString(16)}:${val.toRadixString(16)}');
          return Uint8List.fromList([0x80, 0]);
      }
    }
    return Uint8List(rxLen);
  }

  @override
  Future<void> close() async {}
}

/// A fake ST-Link USB transport that answers only READDEBUGREG with a mapped
/// value — enough to exercise target detection without hardware.
class _FakeTransport implements UsbTransport {
  _FakeTransport(this.regs);
  final Map<int, int> regs;

  @override
  int get productId => 0x3748;
  @override
  String get productName => 'fake';
  @override
  bool get isV3 => false;

  @override
  Future<Uint8List> xfer(List<int> command, {int rxLen = 0, Uint8List? data}) async {
    // READDEBUGREG = [0xF2, 0x36, addr32le] -> [status, _, _, _, value32le]
    if (command.length >= 6 && command[0] == 0xf2 && command[1] == 0x36) {
      final addr = command[2] | command[3] << 8 | command[4] << 16 | command[5] << 24;
      final v = regs[addr] ?? 0;
      return Uint8List.fromList(
          [0x80, 0, 0, 0, v & 0xff, v >> 8 & 0xff, v >> 16 & 0xff, v >> 24 & 0xff]);
    }
    return Uint8List(rxLen);
  }

  @override
  Future<void> close() async {}
}
