---
title: "Portrait alpha VAP renders blank: a unit-height FittedBox aspect box truncates the external texture to zero width on Impeller GLES"
date: 2026-07-20
category: ui-bugs
module: neo_vap
problem_type: ui_bug
component: tooling
severity: high
symptoms:
  - "A portrait (aspect < 1) alpha VAP video renders as a completely blank card; square and landscape clips render fine"
  - "`Invalid texture descriptor` errors spam the log (228 in one controlled A/B run) while every frame is silently discarded"
  - "Reproduces only on Impeller's OpenGLES backend — the identical build renders correctly on Vulkan, so most modern phones never show it"
  - "No crash, no exception, no Dart-side error: the external texture layer just never paints"
root_cause: wrong_api
resolution_type: code_fix
tags: [flutter, impeller, opengles, external-texture, fittedbox, aspect-ratio, android, vap]
related_components: [neo_vap_view, neo_vap_example]
---

# Portrait alpha VAP renders blank: a unit-height FittedBox aspect box truncates the external texture to zero width on Impeller GLES

## Problem

`NeoVapView` sizes itself from the content aspect the native backend reports on init (the vapc `w`/`h`). To express "I only care about the ratio, scale the painting to fit," `_buildTexture` in `lib/src/neo_vap_view.dart` wrapped the external `Texture` in a `FittedBox` around a unit box:

```dart
FittedBox(
  fit: widget.fit,
  child: SizedBox(width: ar, height: 1, child: texture),
)
```

That idiom is correct for ordinary widgets and wrong for an external texture. `FittedBox` scales its child's *painting*, not its layout — the `SizedBox`'s literal layout size is what reaches the texture layer. For the portrait gunmetal pendant (content 710x1134, `ar` ≈ 0.626), the size handed downstream was **0.626 x 1**.

Impeller's GLES external-texture path casts those bounds to `int`:

```cpp
// shell/platform/android/image_external_texture_gl_impeller.cc:38-39
desc.size = {static_cast<int>(bounds.width()), static_cast<int>(bounds.height())};
```

`0.626` truncates to `0`. `TextureDescriptor::IsValid()` rejects the descriptor because `size.IsEmpty()`, and `impeller/renderer/backend/gles/texture_gles.cc:220` logs and drops the frame — every frame, forever.

Square and landscape clips were unaffected: with `ar >= 1` the width truncates to `1`, which is degenerate but not *empty*, so validation passes.

## Symptoms

- A transparent (alpha) VAP video renders as **nothing** — a completely blank card — while the controller reports a healthy state and frames are arriving.
- Only **portrait** clips (`ar < 1`). Square and landscape play fine.
- Logcat spam, 228 lines in a 10-second window:

```
E flutter : [ERROR:flutter/impeller/renderer/backend/gles/texture_gles.cc(220)]
Break on 'ImpellerValidationBreak' to inspect point of failure: Invalid texture descriptor.
```

- **Device-dependent and apparently intermittent.** Two physical phones (CPH2637, TECNO CK8n) rendered the broken code perfectly. A third (vivo V2521) reproduced it at ~130 errors per 5 seconds. See Prevention — this is the tell, not noise.

## What Didn't Work

**Blaming the asset instead of the layout.** A competing hypothesis pinned the failure on vapc content-width 16-byte alignment — i.e. the video metadata rather than the widget tree. It was rejected in adjudication for a specific reason: the agent proposing it had **never read the failing engine code**. The truncation is right there at `image_external_texture_gl_impeller.cc:38`. Read the line that logs the error before theorizing about upstream data.

**Swapping in `AspectRatio`.** Proposed as the fix, rejected: `AspectRatio` is unsafe inside an unconstrained `FittedBox`, which hands its child unbounded constraints.

**`placeholderAsset` — a still image over the texture until the first frame.** This was reached for repeatedly as a way to paper over the blank window, and added and reverted at least three times downstream (neo commits `65359db5`, `9ccb7fd7`, `83e62df9`). It flashes. The fade runs on `firstFrame`, which fires when the texture *has* a frame, not when the compositor has *presented* it, so the swap reads as a visible blink. A flash is worse than a wait. It is now documented as a do-not-use in the widget's own dartdoc at `lib/src/neo_vap_view.dart:42-55`.

**Verifying on the wrong GPU backend.** An entire verification pass was spent on hardware that could not reproduce the bug. Covered below.

## Solution

Keep the `FittedBox` — only the *ratio* of its child matters to it — and give that child a size far from the truncation floor.

```dart
// lib/src/neo_vap_view.dart
/// Height of the aspect box handed to [FittedBox]. Only the ratio matters —
/// this just keeps both dimensions far from the sub-pixel truncation floor.
static const double _aspectBoxHeight = 1000;

child: SizedBox(
  width: ar * _aspectBoxHeight,
  height: _aspectBoxHeight,
  child: texture,
),
```

For `ar` = 0.626 the texture layer now receives `626 x 1000` instead of `0 x 1`. On-screen size is unchanged — `FittedBox` scales the painting to the parent exactly as before.

A regression test in `test/neo_vap_view_test.dart:56-80` pumps the view, emits a 710x1134 `info` event, and asserts the rendered box survives truncation and keeps its ratio:

```dart
expect(box.width.floor(), greaterThan(0));
expect(box.height.floor(), greaterThan(0));
expect(box.width / box.height, closeTo(710 / 1134, 1e-6));
```

The `floor()` calls are the point — they reproduce the engine's `static_cast<int>`. The test was mutation-checked: setting `_aspectBoxHeight = 1` makes it fail.

## Why This Works

`FittedBox` consumes its child's size as a *ratio* and emits a scale transform; the absolute numbers never reach the screen. But they do reach the compositor. Every non-degenerate box with the same ratio produces identical pixels, so the cheapest correct fix is to pick one whose integer floor is comfortably non-zero. 1000 gives roughly three orders of magnitude of headroom above the truncation floor for any plausible aspect ratio — a 0.001 aspect would still floor to 1.

Nothing about the native side, the asset, or the fit behavior changes. The bug was a unit mismatch: a layout size that was only ever meant to be read as a proportion was being read as pixels.

## Prevention

**1. The bug is invisible on Vulkan.** It manifests only on Impeller's **GLES** path. `image_external_texture_gl_impeller.cc` is GL-only; the Vulkan external-texture path has no equivalent int-cast validation, so the same broken code renders perfectly. Both phones that "worked" were natively Vulkan; the one that reproduced it (vivo V2521) fell back Vulkan→GLES.

The consequence is worth stating bluntly: **"I looked at it on my phone and it rendered" is not verification** for this class of bug. Field reports will look intermittent and device-dependent, and half your test fleet will confirm the broken build.

**2. Force the backend rather than hunting for hardware.** Any device can be made to reproduce:

```xml
<!-- example/android/app/src/main/AndroidManifest.xml -->
<meta-data android:name="io.flutter.embedding.android.ImpellerBackend" android:value="opengles" />
```

`FlutterLoader.java:443` converts this to `--impeller-backend=opengles`. Valid values, per `shell/common/switch_defs.h:251`, are `opengles` and `vulkan`.

Confirm which path actually ran — do not assume the meta-data took effect:

```
adb logcat | grep "Using the Impeller rendering backend"
```

It prints `(Vulkan)` from `android_context_vk_impeller.cc:62` or `(OpenGLES)` from `android_context_gl_impeller.cc:104`.

**3. Never express an aspect ratio as a sub-pixel-sized box.** `SizedBox(width: ar, height: 1)` is a widespread idiom for "I only care about the ratio," and it is a trap anywhere the layout size reaches a texture or surface descriptor rather than only the paint transform. Scale it. The general rule: if a size can flow into something that casts to `int`, keep it well above 1.

**4. Cheap detection.** For any external texture that renders blank:

```
adb logcat | grep -c "Invalid texture descriptor"
```

Zero versus hundreds. It is a binary signal and costs nothing — reach for it before reading any Dart.

## Related Issues

- [`best-practices/alpha-vap-crop-to-design-box.md`](../best-practices/alpha-vap-crop-to-design-box.md) — **closest neighbour.** It prescribes the sizing strategy this bug lives inside: let native report the content aspect and render with `BoxFit.contain` in a design-sized box. That guidance is correct; this doc is the constraint its implementation has to satisfy. Same asset, too (the 710x1134 / 0.626 pendant). Read both before touching `NeoVapView` sizing.
- [`architecture-patterns/flutter-plugin-shared-eventchannel.md`](../architecture-patterns/flutter-plugin-shared-eventchannel.md) — a sibling silent-failure mode in this plugin: that one drops *events*, this one drops *frames*, and neither raises an error. Useful debugging instinct: when neo_vap shows nothing, suspect a silent drop before an exception. Note also that its root cause was confirmed on "Android 15, Impeller/Vulkan" — a Vulkan-only verification, which under this learning no longer covers the GLES path.
- [`architecture-patterns/texture-plugin-prewarm-hardening.md`](../architecture-patterns/texture-plugin-prewarm-hardening.md) — same plugin, native cold-start layer rather than Dart layout. Shares only the meta-lesson: a failure invisible on the configuration you happened to test.
- `docs/plans/2026-07-11-001-feat-neo-vap-plugin-plan.md` — defines the Impeller fallback ladder whose first rung is `ImpellerBackend=opengles`, sold as a "one-line downgrade, no code change." This learning qualifies that: GLES is stricter about texture descriptors than Vulkan, so flipping that switch is a different code path that must be re-verified, not a free downgrade. The same caveat applies to the mirrored comment at `example/android/app/src/main/AndroidManifest.xml:33-38`.
- No GitHub issues to link — the repository has issues enabled but none filed. Issue tracking for this work lives in Linear (NEO-2559).
