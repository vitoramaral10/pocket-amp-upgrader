import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_upgrader/src/ui/home_page.dart';

import 'support/fake_pedal.dart';

void main() {
  testWidgets(
    'detects the pedal on start and keeps update disabled without a package',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final FakePedal pedal = FakePedal(image: Uint8List(1024));
      await tester.pumpWidget(MaterialApp(home: HomePage(backend: pedal)));

      final Finder update = find.ancestor(
        of: find.text('Update firmware'),
        matching: find.byWidgetPredicate((Widget w) => w is ButtonStyleButton),
      );
      expect(tester.widget<ButtonStyleButton>(update).onPressed, isNull);

      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 2));
      });
      await tester.pump();

      expect(find.text('1.03'), findsOneWidget);
      expect(find.text('Detect again'), findsOneWidget);
      expect(tester.widget<ButtonStyleButton>(update).onPressed, isNull);
    },
  );
}
