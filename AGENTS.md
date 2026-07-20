# neo_vap

A Flutter plugin that plays transparent (alpha) VAP videos into an external
`Texture` — ExoPlayer/Media3 → GL alpha-composite on Android, AVQueuePlayer →
Metal on iOS. Replaces `flutter_vap_plus`.

## Layout

```
lib/               Dart API — controller, view, vapc parser, method-channel seam
android/           Kotlin backend (NeoVapPlayer, NeoVapRenderer, NeoVapPlugin)
ios/Classes/       Swift backend (NeoVapPlayer, MetalCompositor, Vapc)
test/              Dart tests — run with `flutter test`
example/           Demo app; also the device-verification harness
docs/plans/        Implementation plans
docs/solutions/    Documented solutions to past problems (bugs, best practices,
                   architecture patterns), organized by category with YAML
                   frontmatter (module, tags, problem_type). Relevant when
                   implementing or debugging in an area it already covers.
CONCEPTS.md        Shared domain vocabulary (VAP, vapc, content size, design
                   box, motion headroom) — relevant when orienting to the
                   codebase or discussing domain concepts.
```

## Conventions

- Conventional Commits (`fix:`, `feat:`, `docs:`, `chore(example):`).
- `ponytail:` comments mark deliberate simplifications and name their ceiling.
- The plugin is proprietary and `publish_to: none` — consumers install by git ref.

## Verifying rendering changes on Android

Android has two Impeller backends and they do not fail the same way. A render
bug can be completely invisible on one of them, so name the backend when
claiming a change is device-verified.

```bash
adb logcat | grep "Using the Impeller rendering backend"   # prints (Vulkan) or (OpenGLES)
```

Modern devices default to Vulkan. To exercise the GLES path on any device,
uncomment the `ImpellerBackend` meta-data in
`example/android/app/src/main/AndroidManifest.xml`.

`adb logcat | grep -c "Invalid texture descriptor"` is a cheap binary signal
when an external texture renders blank — see
`docs/solutions/ui-bugs/fittedbox-unit-aspect-box-blanks-texture.md`.
