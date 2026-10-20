// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/material.dart';

import 'src/ui/home_page.dart';

void main() => runApp(const UpgraderApp());

class UpgraderApp extends StatelessWidget {
  const UpgraderApp({super.key});

  static const Color _seed = Color(0xFFB4531F);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pocket AMP Upgrader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: _seed)),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.dark,
        ),
      ),
      home: const HomePage(),
    );
  }
}
