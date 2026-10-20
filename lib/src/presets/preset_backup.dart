// SPDX-License-Identifier: GPL-3.0-only

import 'dart:convert';
import 'dart:typed_data';

import 'mefcs.dart';
import 'preset_session.dart';

/// The 80 preset bodies and the EQ table, as stored in the pedal's flash.
class PresetBackup {
  PresetBackup({
    required this.identity,
    required this.created,
    required this.presets,
    required this.eq,
  }) {
    if (presets.length != presetCount * presetSize ||
        eq.length != eqTableLength) {
      throw const FormatException('Backup has the wrong size.');
    }
    for (int i = 0; i < eqHeader.length; i++) {
      if (eq[i] != eqHeader[i]) {
        throw const FormatException('Backup EQ table is not valid.');
      }
    }
  }

  factory PresetBackup.fromJson(String text) {
    final Object? j = jsonDecode(text);
    if (j is! Map<String, Object?> || j['format'] != format) {
      throw const FormatException('Not a Pocket AMP Upgrader preset backup.');
    }
    return PresetBackup(
      identity: j['pedal'] as String? ?? '?',
      created: DateTime.parse(j['created'] as String),
      presets: base64Decode(j['presets'] as String),
      eq: base64Decode(j['eq'] as String),
    );
  }

  static const String format = 'pocket-amp-upgrader/presets@1';

  final String identity;
  final DateTime created;
  final Uint8List presets;
  final Uint8List eq;

  Uint8List preset(int id) =>
      Uint8List.sublistView(presets, id * presetSize, (id + 1) * presetSize);

  Uint8List eqRecord(int id) {
    final int at = eqHeaderLength + id * eqRecordLength;
    return Uint8List.sublistView(eq, at, at + eqRecordLength);
  }

  String toJson() =>
      const JsonEncoder.withIndent('  ').convert(<String, Object>{
        'format': format,
        'pedal': identity,
        'created': created.toUtc().toIso8601String(),
        'presets': base64Encode(presets),
        'eq': base64Encode(eq),
      });

  String get suggestedFileName {
    String two(int v) => v.toString().padLeft(2, '0');
    final DateTime t = created;
    return 'pocket-amp-presets-${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}.json';
  }
}

/// Which slots differ between two backups.
class PresetDiff {
  const PresetDiff(this.presets, this.eq);
  final List<int> presets;
  final List<int> eq;
  bool get isEmpty => presets.isEmpty && eq.isEmpty;

  static PresetDiff between(PresetBackup want, PresetBackup have) => PresetDiff(
    <int>[
      for (int i = 0; i < presetCount; i++)
        if (!_same(want.preset(i), have.preset(i))) i,
    ],
    <int>[
      for (int i = 0; i < presetCount; i++)
        if (!_same(want.eqRecord(i), have.eqRecord(i))) i,
    ],
  );

  @override
  String toString() {
    String names(List<int> ids) => ids.isEmpty
        ? 'none'
        : ids
              .map((int i) => 'P${(i + 1).toString().padLeft(2, '0')}')
              .join(', ');
    return 'presets: ${names(presets)}; EQ: ${names(eq)}';
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

/// Reads the whole preset bank (presets + EQ table) in 128-byte reads.
Future<PresetBackup> readPresetBank(
  PresetSession session,
  String identity, {
  void Function(double fraction)? onProgress,
}) async {
  const int total = eqTableAddress + eqTableLength;
  const int chunk = 128;
  final Uint8List area = Uint8List(total);
  for (int at = 0; at < total; at += chunk) {
    final int n = at + chunk > total ? total - at : chunk;
    area.setAll(at, await session.readRaw(at, n));
    onProgress?.call((at + n) / total);
  }
  return PresetBackup(
    identity: identity,
    created: DateTime.now(),
    presets: Uint8List.sublistView(area, 0, eqTableAddress),
    eq: Uint8List.sublistView(area, eqTableAddress),
  );
}

/// Writes back only what differs from [backup], commits once, and checks the
/// result by reading everything again. Returns what was restored.
Future<PresetDiff> restorePresetBank(
  PresetSession session,
  PresetBackup backup, {
  void Function(String step, double fraction)? onProgress,
}) async {
  final PresetBackup before = await readPresetBank(
    session,
    backup.identity,
    onProgress: (double f) => onProgress?.call('Reading the pedal', f),
  );
  final PresetDiff diff = PresetDiff.between(backup, before);
  if (diff.isEmpty) {
    return diff;
  }
  final int steps = diff.presets.length + diff.eq.length;
  int done = 0;
  for (final int id in diff.presets) {
    await session.write(
      savePresetPacket(id, backup.preset(id)),
      'saving P${id + 1}',
    );
    onProgress?.call('Writing presets', ++done / steps);
  }
  for (final int id in diff.eq) {
    await session.write(
      saveEqPacket(id, backup.eqRecord(id)),
      'saving the EQ of P${id + 1}',
    );
    onProgress?.call('Writing presets', ++done / steps);
  }
  await session.write(commitPacket(), 'storing the presets');
  final PresetBackup after = await readPresetBank(
    session,
    backup.identity,
    onProgress: (double f) => onProgress?.call('Checking', f),
  );
  final PresetDiff left = PresetDiff.between(backup, after);
  if (!left.isEmpty) {
    throw PresetIoException('Restore did not stick for $left.');
  }
  return diff;
}
