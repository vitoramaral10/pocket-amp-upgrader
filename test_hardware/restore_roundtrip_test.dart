// ignore_for_file: avoid_print
// WRITES PRESETS (P80 only). Exercises the app's restore on a real pedal:
// write a variant of P80 through restore, check it, then restore the original.
//   CONFIRM_WRITE=yes BACKUP_TO=/path.json flutter test test_hardware/restore_roundtrip_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_upgrader/src/midi/alsa_backend.dart';
import 'package:pocket_amp_upgrader/src/pedal_updater.dart';
import 'package:pocket_amp_upgrader/src/presets/mefcs.dart';
import 'package:pocket_amp_upgrader/src/presets/preset_backup.dart';
import 'package:pocket_amp_upgrader/src/presets/preset_service.dart';

void main() {
  final Map<String, String> env = Platform.environment;
  test(
    'restore round trip on P80',
    () async {
      final AlsaBackend backend = AlsaBackend();
      final PresetService presets = PresetService(backend);
      final DetectedPedal pedal = (await PedalUpdater(backend).detect())!;
      final PresetBackup original = await presets.backup(pedal);
      File(env['BACKUP_TO']!).writeAsStringSync(original.toJson());
      print('original saved to ${env['BACKUP_TO']}');

      const int p80 = 79;
      final Uint8List presetsCopy = Uint8List.fromList(original.presets);
      final int volume = presetsCopy[p80 * presetSize];
      presetsCopy[p80 * presetSize] = volume < 100 ? volume + 1 : volume - 1;
      final Uint8List eqCopy = Uint8List.fromList(original.eq);
      final int at = eqHeaderLength + p80 * eqRecordLength;
      final List<int> rec = eqCopy.sublist(at, at + eqRecordLength);
      eqCopy.setAll(
        at,
        rec[2] == 3 ? <int>[1, 0, 2, 0, 0, 0, 0] : <int>[1, 0, 3, 0, 0, 0, 0],
      );
      final PresetBackup variant = PresetBackup(
        identity: original.identity,
        created: DateTime.now(),
        presets: presetsCopy,
        eq: eqCopy,
      );
      print('P80 volume $volume -> ${presetsCopy[p80 * presetSize]}, '
          'EQ $rec -> ${eqCopy.sublist(at, at + eqRecordLength)}');

      final PresetDiff wrote = await presets.restore(pedal, variant);
      print('variant written and checked: $wrote');
      expect(wrote.presets, <int>[p80]);
      expect(wrote.eq, <int>[p80]);

      final PresetDiff back = await presets.restore(pedal, original);
      print('original restored and checked: $back');
      expect(back.presets, <int>[p80]);
      expect(back.eq, <int>[p80]);

      final PresetBackup end = await presets.backup(pedal);
      expect(PresetDiff.between(original, end).isEmpty, isTrue);
      print('pedal matches the original backup');
    },
    skip: env['CONFIRM_WRITE'] == 'yes' ? false : 'set CONFIRM_WRITE=yes',
  );
}
