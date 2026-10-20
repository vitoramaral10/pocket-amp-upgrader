import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_upgrader/src/midi/midi_backend.dart';
import 'package:pocket_amp_upgrader/src/ota_protocol.dart';
import 'package:pocket_amp_upgrader/src/presets/mefcs.dart';
import 'package:pocket_amp_upgrader/src/presets/preset_backup.dart';
import 'package:pocket_amp_upgrader/src/presets/preset_session.dart';

String hex(List<int> b) => b
    .map((int x) => x.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(' ');

/// Simulated preset bank: answers reads, keeps saves in a RAM mirror and
/// copies it to "flash" on Commit.
class FakeBank implements MidiConnection {
  FakeBank(this.flash) : ram = Uint8List.fromList(flash);
  final Uint8List flash;
  final Uint8List ram;
  final List<String> writes = <String>[];
  final StreamController<Uint8List> _out = StreamController<Uint8List>();
  final SysexSplitter _split = SysexSplitter();

  @override
  Stream<Uint8List> get messages => _out.stream;

  void _reply(List<int> packet) =>
      scheduleMicrotask(() => _out.add(mefcsWrap(packet)));

  @override
  Future<void> send(Uint8List sysex) async {
    for (final Uint8List m in _split.add(sysex)) {
      final Uint8List p = mefcsUnwrap(m)!;
      final int addr = p[7] | (p[8] << 8) | (p[9] << 16);
      final int len = p[11] | (p[12] << 8) | (p[13] << 16);
      if (p[2] == 0x23) {
        final List<int> r = <int>[
          0x00,
          0x59,
          0x23,
          (len + 8) & 0xFF,
          (len + 8) >> 8,
          0,
          4,
          ...p.sublist(7, 14),
          ...ram.sublist(addr, addr + len),
          0,
        ];
        r[r.length - 1] = mefcsChecksum(r);
        _reply(r);
      } else if (p[2] == 0x22) {
        if (p[10] == 0xF0) {
          flash.setAll(0, ram);
          writes.add('commit');
        } else {
          ram.setAll(addr, p.sublist(14, 14 + len));
          writes.add(p[3] == 0x64 ? 'preset ${addr ~/ 92}' : 'eq');
        }
        _reply(<int>[0, 0x59, 0, 1, 0, 0, 0, 0xFF]);
      }
    }
  }

  @override
  Future<void> close() => _out.close();
}

Uint8List bank() {
  final Uint8List a = Uint8List(eqTableAddress + eqTableLength);
  for (int i = 0; i < eqTableAddress; i++) {
    a[i] = (i * 13) & 0x7F;
  }
  a.setAll(eqTableAddress, eqHeader);
  return a;
}

void main() {
  test('packets match the bytes measured on the pedal', () {
    expect(hex(commitPacket()), '00 59 22 08 00 00 04 00 00 00 F0 00 00 00 0B');
    expect(savePresetPacket(79, List<int>.filled(92, 0)).last, 0x1F);
    expect(
      savePresetPacket(79, List<int>.filled(92, 0)..[32] = 0x11).last,
      0x0E,
    );
    expect(
      hex(readFlashPacket(7360, 128)),
      '00 59 23 08 00 00 04 C0 1C 00 00 80 00 00 9F',
    );
    expect(
      hex(readFlashPacket(7360 + 512, 66)),
      '00 59 23 08 00 00 04 C0 1E 00 00 42 00 00 DB',
    );
    expect(
      saveEqPacket(79, <int>[1, 0, 6, 0, 0xFA, 0, 3]).sublist(7, 10),
      <int>[0xFB, 0x1E, 0],
    );
  });

  test('wire format round-trips', () {
    final Uint8List p = savePresetPacket(
      3,
      List<int>.generate(92, (int i) => i),
    );
    expect(mefcsUnwrap(mefcsWrap(p)), p);
  });

  test('out-of-range EQ is refused', () {
    expect(
      () => saveEqPacket(0, <int>[1, 0, 7, 0, 0, 0, 0]),
      throwsArgumentError,
    );
  });

  test('backup, then restore writes only what changed', () async {
    final FakeBank pedal = FakeBank(bank());
    final PresetSession s = PresetSession(pedal);
    final PresetBackup saved = await readPresetBank(s, 'Pocket AMP_105');
    expect(saved.presets, pedal.ram.sublist(0, eqTableAddress));
    final PresetBackup copy = PresetBackup.fromJson(saved.toJson());
    expect(copy.presets, saved.presets);

    // A firmware update rewrites two presets and one EQ record.
    pedal.ram[0] ^= 0x7F;
    pedal.ram[79 * 92 + 5] ^= 1;
    pedal.ram[eqTableAddress + eqHeaderLength + 2] = 1;
    pedal.flash.setAll(0, pedal.ram);

    final PresetDiff restored = await restorePresetBank(s, copy);
    expect(restored.presets, <int>[0, 79]);
    expect(restored.eq, <int>[0]);
    expect(pedal.writes, <String>['preset 0', 'preset 79', 'eq', 'commit']);
    expect(pedal.flash, bank());
    await s.close();
  });

  test('restore with nothing to do writes nothing', () async {
    final FakeBank pedal = FakeBank(bank());
    final PresetSession s = PresetSession(pedal);
    final PresetBackup saved = await readPresetBank(s, 'x');
    expect((await restorePresetBank(s, saved)).isEmpty, isTrue);
    expect(pedal.writes, isEmpty);
    await s.close();
  });
}
