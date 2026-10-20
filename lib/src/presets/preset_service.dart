// SPDX-License-Identifier: GPL-3.0-only

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../firmware_package.dart';
import '../midi/midi_backend.dart';
import '../pedal_updater.dart';
import 'preset_backup.dart';
import 'preset_session.dart';

/// Backs up and restores the preset bank of a detected pedal.
class PresetService {
  PresetService(this.backend);

  final MidiBackend backend;

  Future<PresetBackup> backup(
    DetectedPedal pedal, {
    void Function(double fraction)? onProgress,
  }) async {
    _checkPedal(pedal);
    final PresetSession s = PresetSession(await backend.open(pedal.port));
    try {
      return await readPresetBank(s, pedal.identity, onProgress: onProgress);
    } finally {
      await s.close();
    }
  }

  Future<PresetDiff> restore(
    DetectedPedal pedal,
    PresetBackup backup, {
    void Function(String step, double fraction)? onProgress,
  }) async {
    _checkPedal(pedal);
    if (familyOf(backup.identity) != pedal.family) {
      throw PresetIoException(
        'This backup is from a "${familyOf(backup.identity)}", '
        'not a "${pedal.family}".',
      );
    }
    final PresetSession s = PresetSession(await backend.open(pedal.port));
    try {
      return await restorePresetBank(s, backup, onProgress: onProgress);
    } finally {
      await s.close();
    }
  }

  static void _checkPedal(DetectedPedal pedal) {
    if (pedal.inLoader) {
      throw const PresetIoException(
        'The pedal is in update mode; presets can only be read after the '
        'update finishes.',
      );
    }
  }

  /// Keeps a copy in `Documents/Pocket AMP Upgrader`, so a backup taken right
  /// before an update survives the app being closed.
  static Future<File> keepCopy(PresetBackup backup) async {
    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory dir = Directory(
      '${docs.path}${Platform.pathSeparator}Pocket AMP Upgrader',
    );
    await dir.create(recursive: true);
    final File f = File(
      '${dir.path}${Platform.pathSeparator}${backup.suggestedFileName}',
    );
    await f.writeAsString(backup.toJson());
    return f;
  }
}
