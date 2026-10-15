import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'state/session.dart';

void main() => runApp(DocScanApp(session: ScanSession()));

class DocScanApp extends StatelessWidget {
  const DocScanApp({super.key, required this.session});

  final ScanSession session;

  static ThemeData _theme(Brightness b) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF2F6FED), brightness: b);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DocScan',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: HomeScreen(session: session),
    );
  }
}
