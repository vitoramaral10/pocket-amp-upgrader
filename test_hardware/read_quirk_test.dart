// ignore_for_file: avoid_print
// Read-only: settles whether the first payload byte of a flash read is
// overwritten, by reading the same bytes with and without one byte in front.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_upgrader/src/midi/alsa_backend.dart';
import 'package:pocket_amp_upgrader/src/midi/midi_backend.dart';
import 'package:pocket_amp_upgrader/src/presets/preset_session.dart';

void main() {
  test('flash read quirk', () async {
    final AlsaBackend b = AlsaBackend();
    final MidiPortRef port = (await b.listPorts()).firstWhere(
      (MidiPortRef p) => p.name.contains('Pocket'),
    );
    final PresetSession s = PresetSession(await b.open(port));
    try {
      final List<int> plain = await s.readRaw(460, 92);
      final List<int> shifted = (await s.readRaw(459, 93)).sublist(1);
      print('slot5 plain[0..4]   ${plain.sublist(0, 5)}');
      print('slot5 shifted[0..4] ${shifted.sublist(0, 5)}');
      print('rest equal: ${_eq(plain.sublist(1), shifted.sublist(1))}');
      final List<int> big = await s.readRaw(0, 128);
      print('read 128 ok, len ${big.length}, first ${big.sublist(0, 4)}');
      final List<int> s0 = await s.readRaw(0, 92);
      final List<int> s0b = await s.readRaw(0, 93);
      print('slot0 [0] via len92=${s0[0]} len93=${s0b[0]}');
      final String? bin = Platform.environment['BACKUP_BIN'];
      if (bin != null) {
        final List<int> f = File(bin).readAsBytesSync();
        print(
          'backup slot0[0..4] ${f.sublist(0, 5)}  slot5 ${f.sublist(460, 465)}',
        );
      }
    } finally {
      await s.close();
    }
  });
}

bool _eq(List<int> a, List<int> b) {
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return a.length == b.length;
}
