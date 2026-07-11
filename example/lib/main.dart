import 'package:flutter/material.dart';
import 'package:neo_vap/neo_vap.dart';

void main() => runApp(const MyApp());

/// U4 device harness: plays the VAP clips into a NeoVapView over a colored
/// checkerboard so transparency is obvious. Swap the asset with the buttons.
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  static const _clips = <String, ({String video, String? intro, double aspect})>{
    'active (square)': (
      video: 'assets/active_mode_loop_vap.mp4',
      intro: 'assets/active_mode_intro_vap.mp4',
      aspect: 1.0,
    ),
    'gunmetal (16:9)': (
      video: 'assets/gunmetal_pendant_vap_lowres.mp4',
      intro: null,
      aspect: 1504 / 846,
    ),
  };

  String _selected = 'active (square)';

  @override
  Widget build(BuildContext context) {
    final clip = _clips[_selected]!;
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('neo_vap')),
        body: Column(
          children: [
            Expanded(
              // Gradient background: transparency shows if it bleeds through.
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.deepPurple, Colors.teal],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: NeoVapView(
                      // Key forces recreation when the clip changes.
                      key: ValueKey(_selected),
                      videoAsset: clip.video,
                      introAsset: clip.intro,
                      // cover for gunmetal to zoom past its big transparent margins
                      fit: _selected.startsWith('gunmetal')
                          ? BoxFit.cover
                          : BoxFit.contain,
                      aspectRatio: clip.aspect,
                      onError: (m) => debugPrint('neo_vap error: $m'),
                    ),
                  ),
                ),
              ),
            ),
            Wrap(
              children: [
                for (final name in _clips.keys)
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: ChoiceChip(
                      label: Text(name),
                      selected: _selected == name,
                      onSelected: (_) => setState(() => _selected = name),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
