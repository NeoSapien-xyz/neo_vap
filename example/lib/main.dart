import 'package:flutter/material.dart';
import 'package:neo_vap/neo_vap.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Warm the native GL pipeline before the first screen so the first animation
  // isn't stalled by cold EGL init + shader compile (U5).
  NeoVap.prewarm();
  runApp(const MyApp());
}

// Neumorphic palette: elements share the base colour and read as raised/pressed
// purely through a light shadow (top-left) and a dark shadow (bottom-right).
const _base = Color(0xFF23272B);
const _light = Color(0xFF2E343A);
const _dark = Color(0xFF14171A);
const _accent = Color(0xFF00F1A0);

/// Raised (convex) neumorphic surface: same colour as the background, extruded
/// by the paired light/dark shadows.
BoxDecoration _raised(double radius) => BoxDecoration(
      color: _base,
      borderRadius: BorderRadius.circular(radius),
      boxShadow: const [
        BoxShadow(color: _dark, offset: Offset(6, 6), blurRadius: 14),
        BoxShadow(color: _light, offset: Offset(-6, -6), blurRadius: 14),
      ],
    );

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        home: const PendantScreen(),
      );
}

class PendantScreen extends StatefulWidget {
  const PendantScreen({super.key});

  @override
  State<PendantScreen> createState() => _PendantScreenState();
}

class _PendantScreenState extends State<PendantScreen> {
  static const _clips =
      <String, ({String video, String? intro, double? aspect, BoxFit fit})>{
    'cropped': (
      video: 'assets/gunmetal_pendant_vap.mp4',
      intro: null,
      aspect: null, // native reports the real ~0.626 pendant aspect
      fit: BoxFit.contain,
    ),
    'old (bars)': (
      video: 'assets/gunmetal_pendant_vap_lowres.mp4',
      intro: null,
      aspect: 1504 / 846, // bar'd 16:9 content, cover past the margins
      fit: BoxFit.cover,
    ),
    'square': (
      video: 'assets/active_mode_loop_vap.mp4',
      intro: 'assets/active_mode_intro_vap.mp4',
      aspect: 1.0,
      fit: BoxFit.contain,
    ),
  };

  String _selected = 'cropped';

  @override
  Widget build(BuildContext context) {
    final clip = _clips[_selected]!;
    return Scaffold(
      backgroundColor: _base,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  // Raised neumorphic pedestal; the pendant sits on it. NeoVapView
                  // fills its parent, so the inner box (Figma "Neo 2" pendant box,
                  // 236.55×377.87) is what sets the on-screen size.
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: _raised(36),
                    child: SizedBox(
                      width: 236.55,
                      height: 377.87,
                      child: NeoVapView(
                        key: ValueKey(_selected),
                        videoAsset: clip.video,
                        introAsset: clip.intro,
                        fit: clip.fit,
                        aspectRatio: clip.aspect,
                        onError: (m) => debugPrint('neo_vap error: $m'),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 28),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 14,
                runSpacing: 14,
                children: [
                  for (final name in _clips.keys)
                    _NeuToggle(
                      label: name,
                      selected: _selected == name,
                      onTap: () => setState(() => _selected = name),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Neumorphic toggle: raised (convex) when idle, pressed-in (flat + accent ring)
/// when selected.
class _NeuToggle extends StatelessWidget {
  const _NeuToggle({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: selected
              ? BoxDecoration(
                  color: _base,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _accent.withValues(alpha: 0.6)),
                )
              : _raised(16),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? _accent : Colors.white54,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      );
}
