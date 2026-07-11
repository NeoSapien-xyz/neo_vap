import 'package:flutter/material.dart';
import 'package:neo_vap/neo_vap.dart';

void main() => runApp(const MyApp());

/// Minimal harness. The full five-clip example lands in U7; this just exercises
/// the widget API. Playback needs the native backends (U3 iOS / U4 Android).
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('neo_vap example')),
        body: const Center(
          child: AspectRatio(
            aspectRatio: 1,
            child: NeoVapView(
              videoAsset: 'assets/active_mode_loop_vap.mp4',
              introAsset: 'assets/active_mode_intro_vap.mp4',
              placeholderAsset: 'assets/placeholder.png',
              fit: BoxFit.contain,
              aspectRatio: 1,
            ),
          ),
        ),
      ),
    );
  }
}
