# neo_vap

Texture-based transparent (alpha) **VAP** video player for Flutter.

Plays side-by-side alpha VAP clips (an ordinary H.264 mp4 carrying a colour region
+ an alpha region, described by a `vapc` metadata atom) and composites them to
premultiplied RGBA on the GPU, rendering into a Flutter external `Texture` — no
`PlatformView`, no per-frame CPU blending.

- **iOS** — `AVPlayer` (VideoToolbox) → Metal composite → `CVPixelBufferPool` → `FlutterTexture`.
- **Android** — ExoPlayer/Media3 → OpenGL ES composite → `TextureRegistry.SurfaceProducer`.

Same Dart layout on both platforms — ordinary widget sizing, no `Platform.isIOS`
branch, no `Transform.scale`.

## Features

- Transparent alpha video into a plain `Texture` (works under Impeller).
- Gapless intro → loop (`AVQueuePlayer` / ExoPlayer playlist), seamless looping.
- Event-driven placeholder (fades out on the real first frame, never a timer).
- Native reports the clip's true content aspect — the view sizes itself, no
  hardcoded aspect ratio required.
- One-call cold-start `prewarm()` that warms the decode + composite pipeline.

## Install

Not published to pub.dev. Add as a git dependency:

```yaml
dependencies:
  neo_vap:
    git:
      url: https://github.com/NeoSapien-xyz/neo_vap.git
      ref: v0.1.0
```

## Usage

```dart
import 'package:neo_vap/neo_vap.dart';

// Optional: warm the native pipeline once at app init (fire-and-forget).
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  NeoVap.prewarm();
  runApp(const MyApp());
}

// The view fills its parent, so a bounded box sets the on-screen size.
Center(
  child: SizedBox(
    width: 236.55,
    height: 377.87,
    child: NeoVapView(
      videoAsset: 'assets/pendant_loop_vap.mp4',
      introAsset: 'assets/pendant_intro_vap.mp4', // optional one-shot intro
      placeholderAsset: 'assets/pendant_still.png', // optional
      fit: BoxFit.contain,
      // aspectRatio: omit — native reports the real vapc aspect.
      onError: (m) => debugPrint('neo_vap: $m'),
    ),
  ),
)
```

`NeoVapView` fills its parent — constrain it with a `SizedBox`/`Center`; the box
size, not the asset, sets how big the animation renders. Prefer letting native
report the content aspect (`BoxFit.contain`) over hardcoding an `aspectRatio`.

For an externally-owned controller (callbacks, lifecycle), pass a
`NeoVapController` to the view instead of `videoAsset`/`introAsset`.

## Authoring VAP assets

Re-cutting or cropping an alpha VAP has non-obvious pitfalls (the transparent
margins are usually intended motion headroom, not waste). See the recipe and
gotchas in
[`docs/solutions/best-practices/alpha-vap-crop-to-design-box.md`](docs/solutions/best-practices/alpha-vap-crop-to-design-box.md).

## Example

`example/` is a runnable harness (a neumorphic pendant screen) that swaps between
clips to eyeball transparency, sizing, and looping on-device.

## License

Proprietary — see [LICENSE](LICENSE). All rights reserved by Neosapien.
