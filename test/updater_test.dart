import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_upgrader/src/firmware_package.dart';
import 'package:pocket_amp_upgrader/src/midi/midi_backend.dart';
import 'package:pocket_amp_upgrader/src/ota_protocol.dart';
import 'package:pocket_amp_upgrader/src/pedal_updater.dart';

import 'support/fake_pedal.dart';

const UpdateTimings fast = UpdateTimings(
  identityTimeout: Duration(milliseconds: 100),
  loaderIdle: Duration(milliseconds: 400),
  flashIdle: Duration(milliseconds: 400),
  minPhaseTotal: Duration(seconds: 5),
  afterSuccess: Duration(milliseconds: 50),
  waitLoader: Duration(seconds: 3),
  waitReboot: Duration(seconds: 3),
  rescanEvery: Duration(milliseconds: 20),
);

void main() {
  group('protocol', () {
    test('frame round-trips through parse', () {
      final List<int> payload = List<int>.generate(
        520,
        (int i) => (i * 31) & 0xFF,
      );
      final OtaMessage m = parseFrame(buildFrame(0x30, payload))!;
      expect(m.command, 0x30);
      expect(m.payload, payload.map((int b) => b & 0xFF).toList());
    });

    test('identity request matches the bytes the Python tool sent', () {
      // python3 -c 'from ota_pocket_amp import frame; print(frame(0x11).hex())'
      expect(
        buildFrame(cmdIdentity)
            .map((int b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
        'f0003245000000407ff7',
      );
    });

    test('data reply matches the bytes the Python tool sent', () {
      final List<int> payload = <int>[
        7, 0, 0x10, 0, 0, 0, 2, 0, //
        ...List<int>.generate(32, (int i) => 200 + i),
      ];
      expect(
        buildFrame(
          cmdData,
          payload,
        ).map((int b) => b.toRadixString(16).padLeft(2, '0')).join(),
        'f00032414102004003002000000040000048132b5e4c3933674f2147163d1a756a'
        '562f634e2d7b366e5d3d7f061e5c7871644b1b3f6e1ef7',
      );
    });

    test('parse rejects a bad checksum', () {
      final Uint8List f = buildFrame(0x11, <int>[1, 2, 3]);
      f[f.length - 3] ^= 1;
      expect(parseFrame(f), isNull);
    });

    test('splitter reassembles SysEx split across chunks', () {
      final SysexSplitter s = SysexSplitter();
      final Uint8List f = buildFrame(0x11, List<int>.filled(40, 65));
      expect(s.add(<int>[0x90, 0x40, ...f.sublist(0, 10)]), isEmpty);
      final List<Uint8List> out = s.add(<int>[...f.sublist(10), 0xF8]);
      expect(out.single, f);
    });
  });

  group('package', () {
    final Uint8List loader = Uint8List.fromList(
      List<int>.generate(19969, (int i) => i % 251),
    );

    test('parses a synthetic package', () {
      final FirmwarePackage p = FirmwarePackage.parse(
        buildFwsc(loader: loader),
      );
      expect(p.product, 'Pocket AMP_105');
      expect(p.version, '1.05');
      expect(p.productFamily, 'Pocket AMP');
      expect(p.entries.map((FirmwareEntry e) => e.name), <String>[
        'flash.bin',
        'ota.bin',
      ]);
      expect(p.hasKnownLoader, isFalse);
    });

    test('rejects a corrupted package', () {
      final Uint8List raw = buildFwsc(loader: loader);
      raw[2000] ^= 0xFF;
      expect(
        () => FirmwarePackage.parse(raw),
        throwsA(isA<FirmwareFormatException>()),
      );
    });

    final File official = File(Platform.environment['POCKET_AMP_FWSC'] ?? '');
    test('reads the official V1.05 package', () {
      final FirmwarePackage p = FirmwarePackage.parse(
        official.readAsBytesSync(),
      );
      expect(p.product, 'Pocket AMP_105');
      expect(p.hasKnownLoader, isTrue);
      expect(
        p.sha256,
        '9584e81da98215e8e70ddffc28311423ceaa1a5a8a12a478dc68f4679e10902b',
      );
    }, skip: official.existsSync() ? false : 'official package not available');
  });

  group('update', () {
    final Uint8List loader = Uint8List.fromList(
      List<int>.generate(4000, (int i) => i % 13),
    );
    final FirmwarePackage pkg = FirmwarePackage.parse(
      buildFwsc(loader: loader),
    );
    final Set<String> trusted = <String>{pkg.loaderSha256};

    PedalUpdater updater(FakePedal pedal, [List<String>? log]) => PedalUpdater(
      pedal,
      timings: fast,
      trustedLoaders: trusted,
      log: log?.add,
    );

    test('serves both phases and resumes on the rebooted port', () async {
      final FakePedal pedal = FakePedal(image: pkg.image);
      final PedalUpdater up = updater(pedal);

      final DetectedPedal found = (await up.detect())!;
      expect(found.identity, 'Pocket AMP_103');
      expect(
        pedal.sentToBystanders,
        isEmpty,
        reason: 'pedal port is probed first',
      );

      final List<UpdatePhase> phases = <UpdatePhase>[];
      final String result = await up.update(pkg, found, (UpdateProgress p) {
        if (phases.isEmpty || phases.last != p.phase) {
          phases.add(p.phase);
        }
      });

      expect(result, 'Pocket AMP_105');
      expect(
        pedal.sentToBystanders,
        isEmpty,
        reason: 'only the pedal is probed while waiting',
      );
      expect(pedal.arms, 2);
      expect(pedal.loaderReceived, pkg.image);
      expect(pedal.flashReceived, pkg.image);
      expect(phases, <UpdatePhase>[
        UpdatePhase.preparing,
        UpdatePhase.loader,
        UpdatePhase.waitingLoader,
        UpdatePhase.flash,
        UpdatePhase.rebooting,
        UpdatePhase.done,
      ]);
    });

    test(
      'a pedal left in update mode goes straight to the flash phase',
      () async {
        final FakePedal pedal = FakePedal(
          image: pkg.image,
          identity: 'ota-Pocket AMP_103',
        );
        final PedalUpdater up = updater(pedal);
        final DetectedPedal found = (await up.detect())!;
        expect(found.inLoader, isTrue);
        expect(await up.update(pkg, found, (_) {}), 'Pocket AMP_105');
        expect(pedal.arms, 1);
        expect(pedal.loaderReceived, isNull);
      },
    );

    test('a pedal that stops asking for data fails the update', () async {
      final FakePedal pedal = FakePedal(image: pkg.image, stallInFlash: true);
      final PedalUpdater up = updater(pedal);
      final DetectedPedal found = (await up.detect())!;
      await expectLater(
        up.update(pkg, found, (_) {}),
        throwsA(isA<UpdateException>()),
      );
    });

    test(
      'a pedal that comes back on another version fails the update',
      () async {
        final FakePedal pedal = FakePedal(
          image: pkg.image,
          newIdentity: 'Pocket AMP_103',
        );
        final PedalUpdater up = updater(pedal);
        final DetectedPedal found = (await up.detect())!;
        await expectLater(
          up.update(pkg, found, (_) {}),
          throwsA(isA<UpdateException>()),
        );
      },
    );

    test('an untrusted loader is refused before anything is sent', () async {
      final FakePedal pedal = FakePedal(image: pkg.image);
      final PedalUpdater up = PedalUpdater(pedal, timings: fast);
      final DetectedPedal found = (await up.detect())!;
      await expectLater(
        up.update(pkg, found, (_) {}),
        throwsA(isA<UpdateException>()),
      );
      expect(pedal.arms, 0);
    });

    test('blockers refuse a package for another product', () {
      final FirmwarePackage other = FirmwarePackage.parse(
        buildFwsc(product: 'FM-1_015', loader: Uint8List(1000)),
      );
      final List<String> reasons = updater(FakePedal(image: pkg.image))
          .blockers(
            other,
            const DetectedPedal(
              MidiPortRef(id: 'x', name: 'Pocket AMP'),
              'Pocket AMP_103',
            ),
          );
      expect(reasons, hasLength(3));
    });
  });
}
