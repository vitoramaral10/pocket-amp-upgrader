// ignore_for_file: avoid_print
// WRITES FIRMWARE. Runs the app's whole update path on a real pedal on Linux:
// preset backup, firmware update, re-detection and preset restore.
//
//   CONFIRM_FLASH=yes POCKET_AMP_FWSC=/path/Pocket\ AMP.fwsc \
//   BACKUP_TO=/path/backup.json flutter test test_hardware/full_update_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_upgrader/src/firmware_package.dart';
import 'package:pocket_amp_upgrader/src/midi/alsa_backend.dart';
import 'package:pocket_amp_upgrader/src/pedal_updater.dart';
import 'package:pocket_amp_upgrader/src/presets/preset_backup.dart';
import 'package:pocket_amp_upgrader/src/presets/preset_service.dart';

void main() {
  final Map<String, String> env = Platform.environment;
  test(
    'full update on a real pedal',
    () async {
      if (env['TRACE'] == '1') {
        OtaLink.trace = (String l) => print('  $l');
      }
      final AlsaBackend backend = AlsaBackend();
      final int idle = int.parse(env['LOADER_IDLE'] ?? '10');
      final PedalUpdater up = PedalUpdater(
        backend,
        timings: UpdateTimings(loaderIdle: Duration(seconds: idle)),
        log: (String l) => print('[updater] $l'),
      );
      final PresetService presets = PresetService(backend);
      final FirmwarePackage pkg = FirmwarePackage.parse(
        File(env['POCKET_AMP_FWSC']!).readAsBytesSync(),
      );

      final DetectedPedal before = (await up.detect())!;
      print('before: ${before.identity}');
      expect(up.blockers(pkg, before), isEmpty);

      final PresetBackup saved = await presets.backup(before);
      File(env['BACKUP_TO']!).writeAsStringSync(saved.toJson());
      print('presets backed up to ${env['BACKUP_TO']}');

      final Stopwatch t = Stopwatch()..start();
      UpdatePhase? last;
      final String after = await up.update(pkg, before, (UpdateProgress p) {
        if (p.phase != last) {
          last = p.phase;
          print('[${t.elapsed.inSeconds}s] ${p.phase.name}');
        }
      });
      print('update done in ${t.elapsed.inSeconds}s, pedal is "$after"');
      expect(after, pkg.product);

      final DetectedPedal again = (await up.detect())!;
      final PresetBackup changed = await presets.backup(again);
      print('changed by the update: ${PresetDiff.between(saved, changed)}');

      final PresetDiff restored = await presets.restore(again, saved);
      print('restored: $restored');
      final PresetBackup check = await presets.backup(again);
      expect(PresetDiff.between(saved, check).isEmpty, isTrue);
      print('pedal matches the backup taken before the update');
    },
    timeout: const Timeout(Duration(minutes: 8)),
    skip: env['CONFIRM_FLASH'] == 'yes' ? false : 'set CONFIRM_FLASH=yes',
  );
}
