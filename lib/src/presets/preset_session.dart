// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../midi/midi_backend.dart';
import 'mefcs.dart';

class PresetIoException implements Exception {
  const PresetIoException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Request/response over one open port, in M-EFCS packets.
class PresetSession {
  PresetSession(this._conn) {
    _sub = _conn.messages.listen(
      (Uint8List m) {
        final Uint8List? p = mefcsUnwrap(m);
        if (p != null) {
          _queue.add(p);
          _wake();
        }
      },
      onError: (Object e) {
        _gone = true;
        _wake();
      },
      onDone: () {
        _gone = true;
        _wake();
      },
    );
  }

  final MidiConnection _conn;
  late final StreamSubscription<Uint8List> _sub;
  final Queue<Uint8List> _queue = Queue<Uint8List>();
  bool _gone = false;
  Completer<void>? _waiter;

  static const Duration timeout = Duration(seconds: 2);
  static const int attempts = 3;

  void _wake() {
    final Completer<void>? w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) {
      w.complete();
    }
  }

  Future<Uint8List?> _next(Duration left) async {
    while (_queue.isEmpty) {
      if (_gone) {
        throw const PresetIoException('The pedal was disconnected.');
      }
      if (left <= Duration.zero) {
        return null;
      }
      final Stopwatch clock = Stopwatch()..start();
      final Completer<void> w = Completer<void>();
      _waiter = w;
      await w.future.timeout(left, onTimeout: () {});
      left -= clock.elapsed;
    }
    return _queue.removeFirst();
  }

  /// Sends [packet] and returns the first reply accepted by [want].
  Future<Uint8List?> _exchange(
    Uint8List packet,
    bool Function(Uint8List reply) want,
  ) async {
    _queue.clear();
    await _conn.send(mefcsWrap(packet));
    final Stopwatch clock = Stopwatch()..start();
    while (clock.elapsed < timeout) {
      final Uint8List? r = await _next(timeout - clock.elapsed);
      if (r != null && want(r)) {
        return r;
      }
    }
    return null;
  }

  /// Reads [length] (at most 128) bytes of the preset/EQ area. On route 04
  /// the payload comes back intact, byte 0 included (checked on hardware by
  /// reading the same bytes with and without one byte in front).
  Future<Uint8List> readRaw(int address, int length) async {
    final int expected = 14 + length + 1;
    for (int i = 0; i < attempts; i++) {
      final Uint8List? r = await _exchange(
        readFlashPacket(address, length),
        (Uint8List p) => p.length == expected,
      );
      if (r != null) {
        return Uint8List.sublistView(r, 14, r.length - 1);
      }
    }
    throw PresetIoException('No answer reading $length bytes at $address.');
  }

  /// Sends a write and waits for the device ACK.
  Future<void> write(Uint8List packet, String what) async {
    for (int i = 0; i < attempts; i++) {
      final Uint8List? r = await _exchange(packet, isAck);
      if (r != null) {
        return;
      }
    }
    throw PresetIoException('The pedal did not confirm: $what.');
  }

  Future<void> close() async {
    await _sub.cancel();
    try {
      await _conn.close();
    } catch (_) {
      // The pedal may already be gone.
    }
  }
}
