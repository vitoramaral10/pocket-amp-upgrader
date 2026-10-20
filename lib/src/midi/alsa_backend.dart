// SPDX-License-Identifier: GPL-3.0-only
//
// Linux: ALSA rawmidi through libasound, non-blocking, polled from the Dart
// event loop. Ports are enumerated from /dev/snd and /proc/asound, which also
// gives the USB id of each card.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../ota_protocol.dart';
import 'midi_backend.dart';

typedef _OpenC = Int Function(
  Pointer<Pointer<Void>>,
  Pointer<Pointer<Void>>,
  Pointer<Utf8>,
  Int,
);
typedef _OpenD = int Function(
  Pointer<Pointer<Void>>,
  Pointer<Pointer<Void>>,
  Pointer<Utf8>,
  int,
);
typedef _HandleC = Int Function(Pointer<Void>);
typedef _HandleD = int Function(Pointer<Void>);
typedef _IoC = IntPtr Function(Pointer<Void>, Pointer<Uint8>, IntPtr);
typedef _IoD = int Function(Pointer<Void>, Pointer<Uint8>, int);

class _Alsa {
  _Alsa(DynamicLibrary lib)
    : open = lib.lookupFunction<_OpenC, _OpenD>('snd_rawmidi_open'),
      close = lib.lookupFunction<_HandleC, _HandleD>('snd_rawmidi_close'),
      drain = lib.lookupFunction<_HandleC, _HandleD>('snd_rawmidi_drain'),
      write = lib.lookupFunction<_IoC, _IoD>('snd_rawmidi_write'),
      read = lib.lookupFunction<_IoC, _IoD>('snd_rawmidi_read');

  static _Alsa? _instance;
  static _Alsa get instance =>
      _instance ??= _Alsa(DynamicLibrary.open('libasound.so.2'));

  final _OpenD open;
  final _HandleD close;
  final _HandleD drain;
  final _IoD write;
  final _IoD read;

  static const int nonblock = 0x0002;
  static const int eagain = -11;
  static const int eintr = -4;
  // ENODEV, ENXIO, EIO, ESHUTDOWN, EBADFD: the node no longer exists.
  static const Set<int> gone = <int>{-19, -6, -5, -108, -77};
}

class AlsaBackend implements MidiBackend {
  @override
  Future<List<MidiPortRef>> listPorts() async {
    final Directory dev = Directory('/dev/snd');
    if (!dev.existsSync()) {
      return const <MidiPortRef>[];
    }
    final Map<int, String> names = _cardNames();
    final RegExp node = RegExp(r'^midiC(\d+)D(\d+)$');
    final List<(int, int)> found = <(int, int)>[];
    for (final FileSystemEntity e in dev.listSync()) {
      final RegExpMatch? m = node.firstMatch(e.uri.pathSegments.last);
      if (m != null) {
        found.add((int.parse(m.group(1)!), int.parse(m.group(2)!)));
      }
    }
    found.sort(
      ((int, int) a, (int, int) b) =>
          a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2),
    );
    return <MidiPortRef>[
      for (final (int card, int device) in found)
        MidiPortRef(
          id: 'hw:$card,$device,0',
          name: names[card] ?? 'card $card',
          usbId: _usbId(card),
        ),
    ];
  }

  @override
  Future<MidiConnection> open(MidiPortRef port) async {
    final _Alsa alsa = _Alsa.instance;
    final Pointer<Pointer<Void>> inp = calloc<Pointer<Void>>();
    final Pointer<Pointer<Void>> outp = calloc<Pointer<Void>>();
    final Pointer<Utf8> name = port.id.toNativeUtf8();
    try {
      final int r = alsa.open(inp, outp, name, _Alsa.nonblock);
      if (r < 0) {
        throw MidiIoException(
          'Could not open ${port.name} (error $r). '
          'Close other MIDI apps and check permissions on /dev/snd.',
        );
      }
      return _AlsaConnection(alsa, inp.value, outp.value);
    } finally {
      calloc.free(inp);
      calloc.free(outp);
      calloc.free(name);
    }
  }

  static Map<int, String> _cardNames() {
    final File f = File('/proc/asound/cards');
    final Map<int, String> out = <int, String>{};
    if (!f.existsSync()) {
      return out;
    }
    final RegExp line = RegExp(r'^\s*(\d+)\s*\[[^\]]*\]\s*:\s*(.*)$');
    for (final String l in f.readAsLinesSync()) {
      final RegExpMatch? m = line.firstMatch(l);
      if (m == null) {
        continue;
      }
      final String rest = m.group(2)!.trim();
      final int sep = rest.indexOf(' - ');
      out[int.parse(m.group(1)!)] = sep >= 0
          ? rest.substring(sep + 3).trim()
          : rest;
    }
    return out;
  }

  static String? _usbId(int card) {
    final File f = File('/proc/asound/card$card/usbid');
    if (!f.existsSync()) {
      return null;
    }
    final String v = f.readAsStringSync().trim().toLowerCase();
    return v.isEmpty ? null : v;
  }
}

class _AlsaConnection implements MidiConnection {
  _AlsaConnection(this._alsa, this._in, this._out) {
    _pump();
  }

  final _Alsa _alsa;
  Pointer<Void>? _in;
  Pointer<Void>? _out;
  bool _lost = false;
  final StreamController<Uint8List> _messages = StreamController<Uint8List>();
  final SysexSplitter _splitter = SysexSplitter();
  static const int _bufSize = 1024;

  @override
  Stream<Uint8List> get messages => _messages.stream;

  Future<void> _pump() async {
    final Pointer<Uint8> buf = calloc<Uint8>(_bufSize);
    try {
      while (_in != null) {
        final int n = _alsa.read(_in!, buf, _bufSize);
        if (n == _Alsa.eagain || n == _Alsa.eintr || n == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
          continue;
        }
        if (n < 0) {
          _lost = _Alsa.gone.contains(n);
          if (!_messages.isClosed) {
            _messages.addError(MidiPortGone('(read error $n)'));
          }
          await close();
          return;
        }
        for (final Uint8List m in _splitter.add(buf.asTypedList(n))) {
          _messages.add(m);
        }
      }
    } finally {
      calloc.free(buf);
    }
  }

  @override
  Future<void> send(Uint8List sysex) async {
    final Pointer<Void>? out = _out;
    if (out == null) {
      throw const MidiPortGone();
    }
    final Pointer<Uint8> data = calloc<Uint8>(sysex.length);
    try {
      data.asTypedList(sysex.length).setAll(0, sysex);
      int written = 0;
      final Stopwatch clock = Stopwatch()..start();
      while (written < sysex.length) {
        final int r = _alsa.write(out, data + written, sysex.length - written);
        if (r == _Alsa.eagain || r == _Alsa.eintr) {
          if (clock.elapsed > const Duration(seconds: 3)) {
            throw const MidiIoException('MIDI output stalled.');
          }
          await Future<void>.delayed(const Duration(milliseconds: 1));
          continue;
        }
        if (r < 0) {
          _lost = _Alsa.gone.contains(r);
          throw MidiPortGone('(write error $r)');
        }
        written += r;
      }
      _alsa.drain(out);
    } finally {
      calloc.free(data);
    }
  }

  @override
  Future<void> close() async {
    final Pointer<Void>? i = _in;
    final Pointer<Void>? o = _out;
    _in = null;
    _out = null;
    if (o != null) {
      if (!_lost) {
        _alsa.drain(o);
      }
      _alsa.close(o);
    }
    if (i != null) {
      _alsa.close(i);
    }
    if (!_messages.isClosed) {
      await _messages.close();
    }
  }
}
