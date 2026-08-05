// swdart demo — a small cross-platform (web + desktop) flashing & debugging
// utility built entirely on package:swdart.
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:swdart/swdart.dart';

import 'save.dart';

void main() => runApp(const SwdartDemoApp());

const _bg = Color(0xFF0C1017);
const _panel = Color(0xFF161C26);
const _line = Color(0x1FFFFFFF);
const _accent = Color(0xFF35C4C4);
const _ok = Color(0xFF3FB950);
const _warn = Color(0xFFE3B341);
const _danger = Color(0xFFF85149);
const _mono = 'monospace';

class SwdartDemoApp extends StatelessWidget {
  const SwdartDemoApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'swdart',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: _bg,
        colorScheme: const ColorScheme.dark(primary: _accent, surface: _panel),
      ),
      home: const _Home(),
    );
  }
}

class _Home extends StatefulWidget {
  const _Home();
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  final Probe _probe = Probe();
  final List<String> _log = [];
  final _addrCtl = TextEditingController(text: '0x08000000');
  final _memAddrCtl = TextEditingController(text: '0x08000000');
  final _memLenCtl = TextEditingController(text: '0x100');

  ConnectMode _mode = ConnectMode.underReset;
  bool _busy = false;
  String _busyLabel = '';
  double _progress = 0;
  TargetInfo? _target;
  ProtectionState? _protection;
  Uint8List? _fw;
  String? _fwName;
  int? _fwBase; // set when a .hex provides its own base
  List<CoreRegister> _regs = const [];
  String _memDump = '';
  bool _guidedWaiting = false;

  bool get _connected => _probe.isConnected;

  @override
  void initState() {
    super.initState();
    _probe.onLog(_addLog);
  }

  @override
  void dispose() {
    _probe.disconnect();
    super.dispose();
  }

  void _addLog(String line) {
    setState(() {
      _log.add(line);
      if (_log.length > 500) _log.removeRange(0, _log.length - 500);
      if (line.contains('perform the manual step')) _guidedWaiting = true;
    });
  }

  int _parse(TextEditingController c) => int.parse(c.text.trim().replaceFirst('0x', ''), radix: 16);

  void _onProgress(int done, int total) =>
      setState(() => _progress = total > 0 ? done / total : 0);

  Future<void> _run(String label, Future<void> Function() body) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyLabel = label;
      _progress = 0;
    });
    try {
      await body();
    } catch (e) {
      _addLog('[error] $e');
    } finally {
      setState(() {
        _busy = false;
        _busyLabel = '';
        _guidedWaiting = false;
      });
    }
  }

  // ── actions ─────────────────────────────────────────────────────────
  Future<void> _connect() => _run('Connecting', () async {
        final t = await _probe.connect(_mode);
        final p = await _probe.readProtection().catchError((_) => ProtectionState(false, '?'));
        setState(() {
          _target = t;
          _protection = p;
        });
      });

  Future<void> _disconnect() => _run('Disconnecting', () async {
        await _probe.disconnect();
        setState(() {
          _target = null;
          _protection = null;
          _regs = const [];
        });
      });

  Future<void> _loadFile() async {
    const group = XTypeGroup(label: 'firmware', extensions: ['bin', 'hex']);
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (file.name.toLowerCase().endsWith('.hex')) {
      final img = parseIntelHex(utf8.decode(bytes));
      setState(() {
        _fw = img.data;
        _fwBase = img.base;
        _fwName = file.name;
        _addrCtl.text = hex(img.base);
      });
      _addLog('[file] ${file.name}: ${img.data.length} bytes @ ${hex(img.base)} (HEX)');
    } else {
      setState(() {
        _fw = bytes;
        _fwBase = null;
        _fwName = file.name;
      });
      _addLog('[file] ${file.name}: ${bytes.length} bytes (raw)');
    }
  }

  Future<void> _flash() => _run('Flashing', () async {
        final fw = _fw!;
        final base = _fwBase ?? _parse(_addrCtl);
        await _probe.program(base, fw, progress: _onProgress);
        await _probe.resetRun();
        try {
          _protection = await _probe.readProtection();
        } catch (_) {}
      });

  Future<void> _dump() => _run('Dumping', () async {
        final len = (_target?.flashKB ?? 0) > 0 ? _target!.flashKB * 1024 : 0x20000;
        final bytes = await _probe.readFlash(length: len);
        final where = await saveBytes('dump_${DateTime.now().millisecondsSinceEpoch}.bin', bytes);
        _addLog(where == null ? '[dump] cancelled' : '[dump] saved → $where');
      });

  Future<void> _erase() => _run('Erasing', () => _probe.eraseAll());

  Future<void> _verify() => _run('Verifying', () async {
        final base = _fwBase ?? _parse(_addrCtl);
        await _probe.verifyFlash(base, _fw!, progress: _onProgress);
      });

  Future<void> _checkProtection() => _run('Checking protection', () async {
        final p = await _probe.readProtection();
        setState(() => _protection = p);
      });

  Future<void> _setProtection(bool enable) => _run(enable ? 'Locking' : 'Unlocking', () async {
        if (!enable) {
          final ok = await _confirm('Unlock / rescue?',
              'This clears read protection and MASS-ERASES the whole chip.');
          if (!ok) return;
        }
        await _probe.setProtection(enable);
        setState(() => _protection = null);
      });

  Future<void> _readRegs() => _run('Reading registers', () async {
        final regs = await _probe.readRegisters();
        setState(() => _regs = regs);
      });

  Future<void> _readMem() => _run('Reading memory', () async {
        final addr = _parse(_memAddrCtl);
        final bytes = await _probe.readMemory(addr, _parse(_memLenCtl));
        setState(() => _memDump = _hexDump(addr, bytes));
      });

  Future<bool> _confirm(String title, String body) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _panel,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Proceed'),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  // ── UI ──────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: _panel,
        title: const Row(children: [
          Icon(Icons.memory_rounded, color: _accent, size: 22),
          SizedBox(width: 8),
          Text('swdart', style: TextStyle(fontWeight: FontWeight.w700)),
          SizedBox(width: 10),
          Text('flash & debug demo', style: TextStyle(color: Colors.white54, fontSize: 13)),
        ]),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _connectCard(),
              if (_target != null) _targetCard(),
              _programCard(),
              _protectionCard(),
              _debugCard(),
              _logCard(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(String title, List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _panel,
          border: Border.all(color: _line),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(title.toUpperCase(),
                style: const TextStyle(color: Colors.white54, fontSize: 11, letterSpacing: 1)),
          ),
          ...children,
        ]),
      );

  Widget _connectCard() => _card('Probe', [
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          DropdownButton<ConnectMode>(
            value: _mode,
            dropdownColor: _panel,
            onChanged: _connected ? null : (m) => setState(() => _mode = m!),
            items: [
              for (final m in ConnectMode.values) DropdownMenuItem(value: m, child: Text(m.name)),
            ],
          ),
          FilledButton.icon(
            onPressed: _busy ? null : (_connected ? _disconnect : _connect),
            icon: Icon(_connected ? Icons.link_off : Icons.usb_rounded, size: 18),
            label: Text(_connected ? 'Disconnect' : 'Connect'),
          ),
          if (_guidedWaiting)
            FilledButton.tonal(
                onPressed: () => _probe.continueConnect(), child: const Text('Continue')),
          if (_mode == ConnectMode.attachRace && _busy)
            OutlinedButton(onPressed: () => _probe.abort(), child: const Text('Stop')),
        ]),
      ]);

  Widget _targetCard() {
    final t = _target!;
    return _card('Target', [
      Wrap(spacing: 8, runSpacing: 8, children: [
        _chip(t.name, _accent),
        _chip('IDCODE ${hex(t.idcode)}', Colors.white54),
        _chip('${t.flashKB} KB · ${t.pageSize} B pages', Colors.white54),
        _chip(t.family, Colors.white54),
        _chip('${t.programAlign * 8}-bit', Colors.white54),
        if (!t.tested) _chip('untested part', _warn),
      ]),
    ]);
  }

  Widget _programCard() {
    final onFw = _connected && !_busy && _fw != null;
    return _card('Program', [
      Row(children: [
        OutlinedButton.icon(
          onPressed: _busy ? null : _loadFile,
          icon: const Icon(Icons.folder_open_rounded, size: 18),
          label: const Text('Load .bin / .hex'),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(_fwName == null ? 'No firmware loaded' : '$_fwName (${_fw!.length} B)',
              overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: _mono, fontSize: 12)),
        ),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        const Text('Base ', style: TextStyle(color: Colors.white54)),
        SizedBox(
          width: 130,
          child: TextField(
            controller: _addrCtl,
            style: const TextStyle(fontFamily: _mono),
            decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
          ),
        ),
      ]),
      const SizedBox(height: 10),
      Wrap(spacing: 10, runSpacing: 10, children: [
        FilledButton.icon(
            onPressed: onFw ? _flash : null,
            icon: const Icon(Icons.bolt_rounded, size: 18),
            label: const Text('Flash (erase+write+verify)')),
        OutlinedButton.icon(
            onPressed: _connected && !_busy ? _dump : null,
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('Dump')),
        OutlinedButton(onPressed: onFw ? _verify : null, child: const Text('Verify')),
        OutlinedButton(onPressed: _connected && !_busy ? _erase : null, child: const Text('Erase all')),
      ]),
      if (_busy || _progress > 0) ...[
        const SizedBox(height: 12),
        Text('${_busyLabel.isEmpty ? '' : '$_busyLabel · '}${(_progress * 100).round()}%',
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 4),
        LinearProgressIndicator(
            value: _progress > 0 ? _progress : null, color: _accent, backgroundColor: _bg),
      ],
    ]);
  }

  Widget _protectionCard() {
    final on = _connected && !_busy;
    return _card('Read protection', [
      Text(
        _protection == null
            ? 'unknown'
            : _protection!.enabled
                ? 'ENABLED · ${_protection!.level}'
                : 'disabled',
        style: TextStyle(color: _protection?.enabled == true ? _danger : _ok, fontFamily: _mono),
      ),
      const SizedBox(height: 10),
      Wrap(spacing: 10, runSpacing: 10, children: [
        OutlinedButton(onPressed: on ? _checkProtection : null, child: const Text('Check')),
        OutlinedButton(onPressed: on ? () => _setProtection(true) : null, child: const Text('Lock')),
        OutlinedButton(
          onPressed: on ? () => _setProtection(false) : null,
          style: OutlinedButton.styleFrom(foregroundColor: _danger),
          child: const Text('Unlock (erases chip)'),
        ),
      ]),
    ]);
  }

  Widget _debugCard() {
    final on = _connected && !_busy;
    return _card('Debug', [
      Wrap(spacing: 10, runSpacing: 10, children: [
        OutlinedButton(onPressed: on ? () => _run('Halt', _probe.halt) : null, child: const Text('Halt')),
        OutlinedButton(onPressed: on ? () => _run('Run', _probe.resume) : null, child: const Text('Run')),
        OutlinedButton(onPressed: on ? () => _run('Step', _probe.step) : null, child: const Text('Step')),
        OutlinedButton(
            onPressed: on ? () => _run('Reset', _probe.resetHalt) : null, child: const Text('Reset-halt')),
        OutlinedButton(onPressed: on ? _readRegs : null, child: const Text('Registers')),
      ]),
      if (_regs.isNotEmpty) ...[
        const SizedBox(height: 10),
        Wrap(spacing: 14, runSpacing: 4, children: [
          for (final r in _regs)
            Text('${r.name.padRight(4)}=${hex(r.value)}',
                style: const TextStyle(fontFamily: _mono, fontSize: 12, color: Colors.white70)),
        ]),
      ],
      const Divider(color: _line, height: 24),
      Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        const Text('Addr ', style: TextStyle(color: Colors.white54)),
        SizedBox(
            width: 130,
            child: TextField(
                controller: _memAddrCtl,
                style: const TextStyle(fontFamily: _mono),
                decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()))),
        const Text('Len ', style: TextStyle(color: Colors.white54)),
        SizedBox(
            width: 90,
            child: TextField(
                controller: _memLenCtl,
                style: const TextStyle(fontFamily: _mono),
                decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()))),
        OutlinedButton(onPressed: on ? _readMem : null, child: const Text('Read memory')),
      ]),
      if (_memDump.isNotEmpty) ...[
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: _bg, borderRadius: BorderRadius.circular(6)),
          child: SelectableText(_memDump,
              style: const TextStyle(fontFamily: _mono, fontSize: 12, color: Colors.white70)),
        ),
      ],
    ]);
  }

  Widget _logCard() => _card('Log', [
        Container(
          height: 220,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: _bg, borderRadius: BorderRadius.circular(6)),
          child: ListView.builder(
            reverse: true,
            itemCount: _log.length,
            itemBuilder: (_, i) {
              final line = _log[_log.length - 1 - i];
              return Text(line,
                  style: TextStyle(
                      fontFamily: _mono,
                      fontSize: 12,
                      color: line.contains('[error]') ? _danger : Colors.white60));
            },
          ),
        ),
      ]);

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          border: Border.all(color: color.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label, style: TextStyle(color: color, fontSize: 12, fontFamily: _mono)),
      );

  static String _hexDump(int base, Uint8List data) {
    final b = StringBuffer();
    for (var row = 0; row < data.length; row += 16) {
      final slice = data.sublist(row, row + 16 > data.length ? data.length : row + 16);
      final bytes = slice.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');
      final ascii = slice.map((x) => x >= 0x20 && x < 0x7f ? String.fromCharCode(x) : '.').join();
      b.writeln('${hex(base + row)}  ${bytes.padRight(47)}  $ascii');
    }
    return b.toString().trimRight();
  }
}
