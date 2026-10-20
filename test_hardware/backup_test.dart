// ignore_for_file: avoid_print
// Read-only: the app's preset backup must match an independent backup.
//   REF_BIN=backup_flash_X.bin REF_EQ=eq_table_X.hex flutter test test_hardware/backup_test.dart
// Set SAVE_TO=/path.json to keep the backup.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_upgrader/src/midi/alsa_backend.dart';
import 'package:pocket_amp_upgrader/src/pedal_updater.dart';
import 'package:pocket_amp_upgrader/src/presets/preset_backup.dart';
import 'package:pocket_amp_upgrader/src/presets/preset_session.dart';

void main() {
  test('app backup matches the reference backup', () async {
    final AlsaBackend b = AlsaBackend();
    final DetectedPedal pedal = (await PedalUpdater(b).detect())!;
    final PresetSession s = PresetSession(await b.open(pedal.port));
    final Stopwatch t = Stopwatch()..start();
    final PresetBackup bk;
    try {
      bk = await readPresetBank(s, pedal.identity);
    } finally {
      await s.close();
    }
    print('read in ${t.elapsedMilliseconds} ms');
    final Map<String, String> env = Platform.environment;
    if (env['REF_BIN'] != null) {
      final List<int> ref = File(env['REF_BIN']!).readAsBytesSync();
      expect(bk.presets, ref.sublist(0, 7360));
      print('presets match ${env['REF_BIN']}');
    }
    if (env['REF_EQ'] != null) {
      final List<int> ref = File(env['REF_EQ']!)
          .readAsStringSync()
          .trim()
          .split(RegExp(r'\s+'))
          .map((String h) => int.parse(h, radix: 16))
          .toList();
      expect(bk.eq, ref);
      print('EQ matches ${env['REF_EQ']}');
    }
    if (env['SAVE_TO'] != null) {
      File(env['SAVE_TO']!).writeAsStringSync(bk.toJson());
      print('saved ${env['SAVE_TO']}');
    }
  });
}
