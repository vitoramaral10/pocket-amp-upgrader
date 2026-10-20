// ignore_for_file: avoid_print
// Read-only check against a real pedal on Linux: lists ports and asks for the
// identity. Nothing is written. Run with:
//   flutter test test_hardware/detect_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_upgrader/src/firmware_package.dart';
import 'package:pocket_amp_upgrader/src/midi/alsa_backend.dart';
import 'package:pocket_amp_upgrader/src/pedal_updater.dart';

void main() {
  test('finds a Pocket AMP on USB-MIDI', () async {
    final PedalUpdater up = PedalUpdater(AlsaBackend(), log: print);
    final DetectedPedal? pedal = await up.detect();
    expect(pedal, isNotNull);
    print('identity: ${pedal!.identity}  version: ${pedal.version}');
    // Twice in a row: the port must be released cleanly after a probe.
    expect((await up.detect())?.identity, pedal.identity);

    final File official = File(Platform.environment['POCKET_AMP_FWSC'] ?? '');
    if (official.existsSync()) {
      final FirmwarePackage pkg = FirmwarePackage.parse(
        official.readAsBytesSync(),
      );
      expect(up.blockers(pkg, pedal), isEmpty);
    }
  });
}
