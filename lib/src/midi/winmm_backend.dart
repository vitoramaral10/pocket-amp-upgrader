// SPDX-License-Identifier: GPL-3.0-only
//
// Windows: WinMM (winmm.dll) through dart:ffi.
//
// Written here instead of using a plugin because a firmware transfer cannot
// afford a reused output buffer: midiOutLongMsg is asynchronous, so each send
// waits for MHDR_DONE before the header is unprepared and freed. Input is
// opened with CALLBACK_NULL and the SysEx buffers are polled for MHDR_DONE,
// which keeps every callback off foreign threads.

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../ota_protocol.dart';
import 'midi_backend.dart';

final class _MidiHdr extends Struct {
  external Pointer<Uint8> lpData;
  @Uint32()
  external int dwBufferLength;
  @Uint32()
  external int dwBytesRecorded;
  @Uint64()
  external int dwUser;
  @Uint32()
  external int dwFlags;
  external Pointer<_MidiHdr> lpNext;
  @Uint64()
  external int reserved;
  @Uint32()
  external int dwOffset;
  @Array(8)
  external Array<Uint64> dwReserved;
}

typedef _NumDevsC = Uint32 Function();
typedef _NumDevsD = int Function();
typedef _CapsC = Uint32 Function(Uint64, Pointer<Uint8>, Uint32);
typedef _CapsD = int Function(int, Pointer<Uint8>, int);
typedef _OpenC = Uint32 Function(
  Pointer<Pointer<Void>>,
  Uint32,
  Uint64,
  Uint64,
  Uint32,
);
typedef _OpenD = int Function(Pointer<Pointer<Void>>, int, int, int, int);
typedef _HdrC = Uint32 Function(Pointer<Void>, Pointer<_MidiHdr>, Uint32);
typedef _HdrD = int Function(Pointer<Void>, Pointer<_MidiHdr>, int);
typedef _HandleC = Uint32 Function(Pointer<Void>);
typedef _HandleD = int Function(Pointer<Void>);

class _WinMm {
  _WinMm(DynamicLibrary l)
    : inNumDevs = l.lookupFunction<_NumDevsC, _NumDevsD>('midiInGetNumDevs'),
      outNumDevs = l.lookupFunction<_NumDevsC, _NumDevsD>('midiOutGetNumDevs'),
      inCaps = l.lookupFunction<_CapsC, _CapsD>('midiInGetDevCapsW'),
      outCaps = l.lookupFunction<_CapsC, _CapsD>('midiOutGetDevCapsW'),
      inOpen = l.lookupFunction<_OpenC, _OpenD>('midiInOpen'),
      outOpen = l.lookupFunction<_OpenC, _OpenD>('midiOutOpen'),
      inPrepare = l.lookupFunction<_HdrC, _HdrD>('midiInPrepareHeader'),
      inUnprepare = l.lookupFunction<_HdrC, _HdrD>('midiInUnprepareHeader'),
      inAddBuffer = l.lookupFunction<_HdrC, _HdrD>('midiInAddBuffer'),
      inStart = l.lookupFunction<_HandleC, _HandleD>('midiInStart'),
      inReset = l.lookupFunction<_HandleC, _HandleD>('midiInReset'),
      inClose = l.lookupFunction<_HandleC, _HandleD>('midiInClose'),
      outPrepare = l.lookupFunction<_HdrC, _HdrD>('midiOutPrepareHeader'),
      outUnprepare = l.lookupFunction<_HdrC, _HdrD>('midiOutUnprepareHeader'),
      outLongMsg = l.lookupFunction<_HdrC, _HdrD>('midiOutLongMsg'),
      outReset = l.lookupFunction<_HandleC, _HandleD>('midiOutReset'),
      outClose = l.lookupFunction<_HandleC, _HandleD>('midiOutClose');

  static _WinMm? _instance;
  static _WinMm get instance =>
      _instance ??= _WinMm(DynamicLibrary.open('winmm.dll'));

  final _NumDevsD inNumDevs;
  final _NumDevsD outNumDevs;
  final _CapsD inCaps;
  final _CapsD outCaps;
  final _OpenD inOpen;
  final _OpenD outOpen;
  final _HdrD inPrepare;
  final _HdrD inUnprepare;
  final _HdrD inAddBuffer;
  final _HandleD inStart;
  final _HandleD inReset;
  final _HandleD inClose;
  final _HdrD outPrepare;
  final _HdrD outUnprepare;
  final _HdrD outLongMsg;
  final _HandleD outReset;
  final _HandleD outClose;

  static const int mhdrDone = 0x1;
  static const int callbackNull = 0;

  /// MIDIINCAPSW / MIDIOUTCAPSW: WORD wMid, WORD wPid, UINT version, then
  /// WCHAR szPname[32] at offset 8.
  String name(bool input, int index) {
    final Pointer<Uint8> caps = calloc<Uint8>(128);
    try {
      final int r = input
          ? inCaps(index, caps, 128)
          : outCaps(index, caps, 128);
      if (r != 0) {
        return '';
      }
      return (caps + 8).cast<Utf16>().toDartString();
    } finally {
      calloc.free(caps);
    }
  }
}

class WinMmBackend implements MidiBackend {
  @override
  Future<List<MidiPortRef>> listPorts() async {
    final _WinMm w = _WinMm.instance;
    final List<String> ins = <String>[
      for (int i = 0; i < w.inNumDevs(); i++) w.name(true, i),
    ];
    final List<String> outs = <String>[
      for (int i = 0; i < w.outNumDevs(); i++) w.name(false, i),
    ];
    // Pair the k-th input with the k-th output of the same name. Extra ports
    // of one device are named "MIDIIN2 (x)" / "MIDIOUT2 (x)", so the
    // direction is dropped before comparing.
    String key(String n) => n.replaceAll(RegExp(r'MIDI(IN|OUT)'), 'MIDI');
    final List<MidiPortRef> ports = <MidiPortRef>[];
    final Set<int> usedOut = <int>{};
    for (int i = 0; i < ins.length; i++) {
      if (ins[i].isEmpty) {
        continue;
      }
      for (int o = 0; o < outs.length; o++) {
        if (!usedOut.contains(o) && key(outs[o]) == key(ins[i])) {
          usedOut.add(o);
          ports.add(MidiPortRef(id: '$i,$o', name: ins[i]));
          break;
        }
      }
    }
    return ports;
  }

  @override
  Future<MidiConnection> open(MidiPortRef port) async {
    final _WinMm w = _WinMm.instance;
    final List<String> ids = port.id.split(',');
    final int inIndex = int.parse(ids[0]);
    final int outIndex = int.parse(ids[1]);
    final Pointer<Pointer<Void>> h = calloc<Pointer<Void>>();
    try {
      int r = w.outOpen(h, outIndex, 0, 0, _WinMm.callbackNull);
      if (r != 0) {
        throw MidiIoException(
          'Could not open MIDI output "${port.name}" (WinMM error $r). '
          'Close the M-VAVE app and any other MIDI software.',
        );
      }
      final Pointer<Void> out = h.value;
      r = w.inOpen(h, inIndex, 0, 0, _WinMm.callbackNull);
      if (r != 0) {
        w.outClose(out);
        throw MidiIoException(
          'Could not open MIDI input "${port.name}" (WinMM error $r). '
          'Close the M-VAVE app and any other MIDI software.',
        );
      }
      return _WinMmConnection(w, h.value, out);
    } finally {
      calloc.free(h);
    }
  }
}

class _WinMmConnection implements MidiConnection {
  _WinMmConnection(this._w, this._in, this._out) {
    for (int i = 0; i < _inCount; i++) {
      final Pointer<_MidiHdr> hdr = calloc<_MidiHdr>();
      hdr.ref.lpData = calloc<Uint8>(_inSize);
      hdr.ref.dwBufferLength = _inSize;
      _w.inPrepare(_in!, hdr, sizeOf<_MidiHdr>());
      _w.inAddBuffer(_in!, hdr, sizeOf<_MidiHdr>());
      _inHeaders.add(hdr);
    }
    _w.inStart(_in!);
    _pump();
  }

  final _WinMm _w;
  Pointer<Void>? _in;
  Pointer<Void>? _out;
  final List<Pointer<_MidiHdr>> _inHeaders = <Pointer<_MidiHdr>>[];
  final StreamController<Uint8List> _messages = StreamController<Uint8List>();
  final SysexSplitter _splitter = SysexSplitter();
  static const int _inCount = 8;
  static const int _inSize = 1024;

  @override
  Stream<Uint8List> get messages => _messages.stream;

  /// Buffers complete in the order they were queued, so they are drained in
  /// that order to keep multi-buffer SysEx contiguous.
  Future<void> _pump() async {
    int next = 0;
    while (_in != null) {
      final Pointer<_MidiHdr> hdr = _inHeaders[next];
      if (hdr.ref.dwFlags & _WinMm.mhdrDone == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
        continue;
      }
      final int n = hdr.ref.dwBytesRecorded;
      if (n > 0) {
        for (final Uint8List m in _splitter.add(
          hdr.ref.lpData.asTypedList(n),
        )) {
          _messages.add(m);
        }
      }
      hdr.ref.dwBytesRecorded = 0;
      hdr.ref.dwFlags &= ~_WinMm.mhdrDone;
      final Pointer<Void>? h = _in;
      if (h == null) {
        return;
      }
      if (_w.inAddBuffer(h, hdr, sizeOf<_MidiHdr>()) != 0) {
        if (!_messages.isClosed) {
          _messages.addError(const MidiPortGone('(input buffer rejected)'));
        }
        return;
      }
      next = (next + 1) % _inCount;
    }
  }

  @override
  Future<void> send(Uint8List sysex) async {
    final Pointer<Void>? out = _out;
    if (out == null) {
      throw const MidiPortGone();
    }
    final Pointer<_MidiHdr> hdr = calloc<_MidiHdr>();
    final Pointer<Uint8> data = calloc<Uint8>(sysex.length);
    bool prepared = false;
    bool queued = false;
    try {
      data.asTypedList(sysex.length).setAll(0, sysex);
      hdr.ref.lpData = data;
      hdr.ref.dwBufferLength = sysex.length;
      hdr.ref.dwBytesRecorded = sysex.length;
      int r = _w.outPrepare(out, hdr, sizeOf<_MidiHdr>());
      if (r != 0) {
        throw MidiPortGone('(prepare error $r)');
      }
      prepared = true;
      r = _w.outLongMsg(out, hdr, sizeOf<_MidiHdr>());
      if (r != 0) {
        throw MidiPortGone('(send error $r)');
      }
      queued = true;
      final Stopwatch clock = Stopwatch()..start();
      while (hdr.ref.dwFlags & _WinMm.mhdrDone == 0) {
        if (clock.elapsed > const Duration(seconds: 3)) {
          throw const MidiIoException('MIDI output stalled.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      queued = false;
    } finally {
      if (queued) {
        // Ask the driver to hand the buffer back, and wait until it does.
        _w.outReset(out);
        final Stopwatch clock = Stopwatch()..start();
        while (hdr.ref.dwFlags & _WinMm.mhdrDone == 0 &&
            clock.elapsed < const Duration(seconds: 1)) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }
      // Free only what the driver confirmed it released; if unprepare fails
      // it may still read the buffer, so leaking it is the safe choice.
      if (!prepared || _w.outUnprepare(out, hdr, sizeOf<_MidiHdr>()) == 0) {
        calloc.free(data);
        calloc.free(hdr);
      }
    }
  }

  @override
  Future<void> close() async {
    final Pointer<Void>? i = _in;
    final Pointer<Void>? o = _out;
    _in = null;
    _out = null;
    if (i != null) {
      _w.inReset(i); // marks every queued buffer done
      // Free only the buffers the driver confirmed it released (see send).
      final List<Pointer<_MidiHdr>> released = <Pointer<_MidiHdr>>[
        for (final Pointer<_MidiHdr> hdr in _inHeaders)
          if (_w.inUnprepare(i, hdr, sizeOf<_MidiHdr>()) == 0) hdr,
      ];
      _w.inClose(i);
      for (final Pointer<_MidiHdr> hdr in released) {
        calloc.free(hdr.ref.lpData);
        calloc.free(hdr);
      }
      _inHeaders.clear();
    }
    if (o != null) {
      _w.outReset(o);
      _w.outClose(o);
    }
    if (!_messages.isClosed) {
      await _messages.close();
    }
  }
}
