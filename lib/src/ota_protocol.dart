// SPDX-License-Identifier: GPL-3.0-only
//
// Wire format of the JieLi/M-VAVE USB-MIDI update protocol, as used by the
// FM1 Open browser updater (m-vave/fm1_open, sdk/WebUpdate.js):
//
//   frame    F0 + pack7([00 59 cmd len_lo len_hi 00 payload... ~sum]) + F7
//   0x11     identity: 27 ASCII bytes ("Pocket AMP_105", "ota-Pocket AMP_103")
//   arm      F0 22 24 35 7F F7 (raw, not packed) starts a transfer
//   0x30     the pedal asks for [seq, address u32, size u24]; the host answers
//            with the same 8 bytes followed by the data. Address 0xE0000000
//            (loader phase) or 0xF0000000 (flash phase) ends the phase and is
//            answered with "success\0".

import 'dart:typed_data';

const int cmdIdentity = 0x11;
const int cmdData = 0x30;
const int finishLoader = 0xE0000000;
const int finishFlash = 0xF0000000;
final Uint8List armMessage = Uint8List.fromList(<int>[
  0xF0,
  0x22,
  0x24,
  0x35,
  0x7F,
  0xF7,
]);
final Uint8List successReply = Uint8List.fromList('success\u0000'.codeUnits);

/// Packs 8-bit bytes into a 7-bit stream, least significant bits first.
List<int> pack7(List<int> data) {
  final List<int> out = <int>[];
  int bits = 0;
  int value = 0;
  for (final int b in data) {
    value |= b << bits;
    bits += 8;
    while (bits >= 7) {
      out.add(value & 0x7F);
      value >>= 7;
      bits -= 7;
    }
  }
  if (bits > 0) {
    out.add(value & 0x7F);
  }
  return out;
}

/// Builds one SysEx frame for [command] carrying [payload].
Uint8List buildFrame(int command, [List<int> payload = const <int>[]]) {
  if (payload.length > 520) {
    throw ArgumentError('payload too long');
  }
  int sum = 0;
  for (final int b in payload) {
    sum += b;
  }
  final List<int> body = <int>[
    0,
    0x59,
    command,
    payload.length & 0xFF,
    payload.length >> 8,
    0,
    ...payload,
    ~sum & 0xFF,
  ];
  return Uint8List.fromList(<int>[0xF0, ...pack7(body), 0xF7]);
}

/// A decoded frame from the pedal.
class OtaMessage {
  const OtaMessage(this.command, this.payload);
  final int command;
  final Uint8List payload;
}

/// Decodes one complete SysEx message, or returns null if it is not a valid
/// frame of this protocol (other traffic is simply ignored).
OtaMessage? parseFrame(List<int> msg) {
  if (msg.length < 10 ||
      msg.length > 608 ||
      msg.first != 0xF0 ||
      msg.last != 0xF7) {
    return null;
  }
  final List<int> raw = <int>[];
  int bits = 0;
  int value = 0;
  for (int i = 1; i < msg.length - 1; i++) {
    final int b = msg[i];
    if (b > 127) {
      return null;
    }
    value |= b << bits;
    bits += 7;
    if (bits >= 8) {
      raw.add(value & 0xFF);
      value >>= 8;
      bits -= 8;
    }
  }
  if (bits >= 7 ||
      value != 0 ||
      raw.length < 7 ||
      raw[0] != 0 ||
      raw[1] != 0x59) {
    return null;
  }
  final int declared = raw[3] | (raw[4] << 8) | (raw[5] << 16);
  if (declared != raw.length - 7) {
    return null;
  }
  int sum = 0;
  for (int i = 6; i < raw.length; i++) {
    sum += raw[i];
  }
  if (sum & 0xFF != 0xFF) {
    return null;
  }
  return OtaMessage(raw[2], Uint8List.fromList(raw.sublist(6, raw.length - 1)));
}

/// Splits a raw MIDI byte stream into complete SysEx messages.
class SysexSplitter {
  List<int>? _buf;

  /// Feeds [chunk] and returns every SysEx it completes.
  List<Uint8List> add(List<int> chunk) {
    final List<Uint8List> out = <Uint8List>[];
    for (final int b in chunk) {
      if (b == 0xF0) {
        _buf = <int>[b];
      } else if (_buf != null) {
        if (b >= 0xF8) {
          continue; // real-time bytes may appear anywhere
        }
        _buf!.add(b);
        if (b == 0xF7) {
          out.add(Uint8List.fromList(_buf!));
          _buf = null;
        } else if (b > 0x7F || _buf!.length > 4096) {
          _buf = null;
        }
      }
    }
    return out;
  }

  void reset() => _buf = null;
}

/// Reads a little-endian unsigned integer.
int readLe(List<int> b, int at, int n) {
  int v = 0;
  for (int i = n - 1; i >= 0; i--) {
    v = (v << 8) | b[at + i];
  }
  return v;
}

/// ASCII up to the first NUL.
String asciiZ(List<int> b) {
  final int end = b.indexOf(0);
  return String.fromCharCodes(end < 0 ? b : b.sublist(0, end));
}
