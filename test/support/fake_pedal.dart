import 'dart:async';
import 'dart:typed_data';

import 'package:pocket_amp_upgrader/src/firmware_package.dart';
import 'package:pocket_amp_upgrader/src/midi/midi_backend.dart';
import 'package:pocket_amp_upgrader/src/ota_protocol.dart';

/// Builds a valid `.fwsc` with a flash image and a loader whose bytes are
/// [loader]. [product] is interleaved the way M-VAVE packages carry it.
Uint8List buildFwsc({
  String product = 'Pocket AMP_105',
  required Uint8List loader,
  int flashSize = 16384,
}) {
  const int count = 2;
  final int dataStart = 64 + count * 80;
  final Uint8List flash = Uint8List(flashSize);
  for (int i = 0; i < flash.length; i++) {
    flash[i] = (i * 7 + 3) & 0xFF;
  }
  final int loaderOffset = dataStart + flash.length;
  final int total = loaderOffset + loader.length;
  final Uint8List image = Uint8List(total);
  image.setAll(dataStart, flash);
  image.setAll(loaderOffset, loader);

  Uint8List entry(int type, String name, int offset, Uint8List data) {
    final ByteData e = ByteData(80);
    e.setUint16(0, type, Endian.little);
    e.setUint16(4, crc16(data), Endian.little);
    e.setUint32(8, offset, Endian.little);
    e.setUint32(12, data.length, Endian.little);
    e.setUint32(16, data.length, Endian.little);
    final Uint8List b = e.buffer.asUint8List();
    b.setAll(64, name.codeUnits);
    return ufwDecode(b); // the cipher is its own inverse
  }

  final Uint8List table = Uint8List(count * 80)
    ..setAll(0, entry(0, 'flash.bin', dataStart, flash))
    ..setAll(80, entry(100, 'ota.bin', loaderOffset, loader));
  image.setAll(64, table);

  final ByteData head = ByteData(64);
  head.setUint16(2, crc16(table), Endian.little);
  head.setUint32(4, total, Endian.little);
  head.setUint16(8, count, Endian.little);
  final Uint8List hb = head.buffer.asUint8List();
  hb.setAll(16, 'AC791N'.codeUnits);
  head.setUint16(0, crc16(hb.sublist(2)), Endian.little);
  image.setAll(0, ufwDecode(hb));

  final BytesBuilder raw = BytesBuilder();
  for (int i = 0; i < 20; i++) {
    raw.add(image.sublist(i * 47, i * 47 + 47));
    raw.addByte(
      i < product.length ? (product.codeUnitAt(i) + i + 1) & 0xFF : 125,
    );
  }
  raw.add(image.sublist(940));
  return raw.toBytes();
}

/// A simulated pedal on a simulated MIDI bus. It reboots between phases: the
/// port disappears and comes back with a new identity, like the real one.
class FakePedal implements MidiBackend {
  FakePedal({
    required this.image,
    this.identity = 'Pocket AMP_103',
    this.newIdentity = 'Pocket AMP_105',
    this.chunk = 512,
    this.stallInFlash = false,
    this.stallInLoader = false,
    this.rebootDelay = const Duration(milliseconds: 30),
  });

  final Uint8List image;
  String identity;
  final String newIdentity;
  final int chunk;
  final bool stallInFlash;

  /// Reads the first blocks and goes quiet, like a Pocket AMP offered the
  /// version it already runs.
  final bool stallInLoader;
  final Duration rebootDelay;

  /// Other devices on the bus, which never answer.
  final List<MidiPortRef> bystanders = <MidiPortRef>[
    const MidiPortRef(id: 'synth', name: 'Some Synth'),
  ];

  bool present = true;
  final List<String> sentToBystanders = <String>[];
  Uint8List? loaderReceived;
  Uint8List? flashReceived;
  int arms = 0;
  _FakeConnection? _open;

  MidiPortRef get port => MidiPortRef(
    id: 'pedal',
    name: identity.startsWith('ota-') ? 'USB Composite Device' : 'Pocket AMP',
  );

  @override
  Future<List<MidiPortRef>> listPorts() async => <MidiPortRef>[
    ...bystanders,
    if (present) port,
  ];

  @override
  Future<MidiConnection> open(MidiPortRef p) async {
    if (p.id != 'pedal') {
      return _SilentConnection(this, p.id);
    }
    if (!present) {
      throw const MidiPortGone();
    }
    return _open = _FakeConnection(this);
  }

  void _reboot(String next) {
    present = false;
    _open?._gone();
    Timer(rebootDelay, () {
      identity = next;
      present = true;
    });
  }

  Future<void> _transfer(_FakeConnection c) async {
    final bool loaderPhase = !identity.startsWith('ota-');
    final Uint8List got = Uint8List(image.length);
    int seq = 0;
    for (int at = 0; at < image.length; at += chunk) {
      if (stallInLoader && loaderPhase && at >= 3 * chunk) {
        return;
      }
      if (stallInFlash && !loaderPhase && at >= image.length ~/ 2) {
        return; // stop asking: the host must time out
      }
      final int size = at + chunk > image.length ? image.length - at : chunk;
      final Uint8List reply = await c.ask(seq++, at, size);
      got.setAll(at, reply.sublist(8));
    }
    final int finish = loaderPhase ? finishLoader : finishFlash;
    final Uint8List done = await c.ask(seq, finish, 8);
    if (String.fromCharCodes(done.sublist(8)) != 'success\u0000') {
      throw StateError('no success');
    }
    if (loaderPhase) {
      loaderReceived = got;
      _reboot('ota-$identity');
    } else {
      flashReceived = got;
      _reboot(newIdentity);
    }
  }
}

class _SilentConnection implements MidiConnection {
  _SilentConnection(this.bus, this.id);
  final FakePedal bus;
  final String id;
  final StreamController<Uint8List> _c = StreamController<Uint8List>();
  @override
  Stream<Uint8List> get messages => _c.stream;
  @override
  Future<void> send(Uint8List sysex) async => bus.sentToBystanders.add(id);
  @override
  Future<void> close() => _c.close();
}

class _FakeConnection implements MidiConnection {
  _FakeConnection(this.pedal);
  final FakePedal pedal;
  final StreamController<Uint8List> _out = StreamController<Uint8List>();
  Completer<Uint8List>? _pending;
  bool _closed = false;

  @override
  Stream<Uint8List> get messages => _out.stream;

  void _gone() {
    if (!_closed) {
      _closed = true;
      _out.addError(const MidiPortGone());
      _out.close();
    }
  }

  Future<Uint8List> ask(int seq, int address, int size) {
    final ByteData r = ByteData(8)
      ..setUint8(0, seq & 0xFF)
      ..setUint32(1, address, Endian.little);
    r.setUint8(5, size & 0xFF);
    r.setUint8(6, (size >> 8) & 0xFF);
    r.setUint8(7, (size >> 16) & 0xFF);
    _pending = Completer<Uint8List>();
    _out.add(buildFrame(cmdData, r.buffer.asUint8List()));
    return _pending!.future;
  }

  @override
  Future<void> send(Uint8List sysex) async {
    if (_closed) {
      throw const MidiPortGone();
    }
    if (_listEq(sysex, armMessage)) {
      pedal.arms++;
      scheduleMicrotask(() => pedal._transfer(this));
      return;
    }
    final OtaMessage? m = parseFrame(sysex);
    if (m == null) {
      return;
    }
    if (m.command == cmdIdentity) {
      final Uint8List id = Uint8List(27)..setAll(0, pedal.identity.codeUnits);
      scheduleMicrotask(() => _out.add(buildFrame(cmdIdentity, id)));
    } else if (m.command == cmdData) {
      final Completer<Uint8List>? p = _pending;
      _pending = null;
      p?.complete(m.payload);
    }
  }

  @override
  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      await _out.close();
    }
  }
}

bool _listEq(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
