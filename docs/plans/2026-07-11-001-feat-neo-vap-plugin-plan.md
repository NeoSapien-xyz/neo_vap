---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
type: feat
title: "feat: neo_vap — texture-based transparent-video plugin for onboarding"
created: 2026-07-11
---

# feat: `neo_vap` — texture-based transparent (alpha) video plugin

> Canonical home per ce-plan is `docs/plans/2026-07-11-001-feat-neo-vap-plugin-plan.md`.
> Held in the harness plan file during plan mode; relocate on approval.

---

## Context / Problem Frame

The neo onboarding (pendant-pairing + light-indicators screens) plays Tencent-VAP transparent
animations. This has been fought for ~2 months across two plugin forks. Established facts from the
investigation:

- **Videos are valid VAP — verified, no issues whatsoever.** All 5 assets: full-decode scan is clean
  (every frame, zero corruption); `vapc` geometry is internally consistent (RGB/alpha regions within frame
  bounds, `content == rgbFrame`, `vapc.f == nb_frames`, fps match, alpha aspect == RGB aspect at a uniform
  0.50 scale); h264 Main **L4.0**, within Android's 8,192 MB/frame decode cap. Content sizes: active/charging
  = **1000×1000 square**, gunmetal = **1504×846 (16:9)**. The assets were never the problem — only the
  plugin's iOS display layer (it ignored `fit`).
- **Current iOS pain = cold-start latency**: a few seconds before the first frame (Metal device +
  shader compile + decoder warmup on first play); intro + loop *do* play once warm.
- **All existing wrappers wrap the same frozen Tencent natives** (`QGVAPlayer` iOS 1.0.7/1.0.19,
  `animplayer` Android 2.0.28) via **PlatformView**. PlatformView is the source of the whole bug
  family: iOS ignores the `fit` param (CENTER_CROP → `Transform.scale(2.3)` hack), zero-bounds sizing
  races, dispose `stop()` → `MissingPluginException`, no native loop.
- The user forked **both** plugins and fixed much of this (iOS CENTER_CROP frame-math, native loop,
  `playAsset`, prewarm, "3 root causes") but still hit "huge limitations": **the upstream native SDKs
  are frozen/abandoned**, and every iOS fix is a brittle reach into `QGVAPlayer`'s private internals.

**Decision made with the user:** stop maintaining forks of dead upstreams; build a plugin **neo** owns —
`neo_vap` — on a maintained foundation.

**Industry research (VAP, ByteDance AlphaPlayer, Jake Archibald's `<stacked-alpha-video>`, fvp/libpag)
all independently converged on one architecture**, which resolves every problem above:

> Pack alpha into an **ordinary opaque** video (side-by-side RGB + alpha). Hardware-decode it with the
> **OS's universal video decoder** (which every device has and Apple/Google maintain). Composite the
> alpha in a **small GPU shader**. Render into a **Flutter external Texture** — not a PlatformView.

**Intended outcome:** a small, maintainable, texture-based `neo_vap` plugin that plays the existing
VAP assets with correct sizing on both platforms, no cold-start jank, no platform-view races, backed
by OS decoders instead of a dead SDK — and the onboarding screens migrated onto it with the hack pile
deleted.

---

## Key Technical Decisions

- **KTD-1 — External Texture, not PlatformView.** Register a texture with `TextureRegistry`; the
  native decoder renders frames into a `CVPixelBuffer` (iOS) / `SurfaceTexture` (Android); Flutter
  composites a `TextureLayer`. The `Texture` widget is a normal `RenderObject` sized by ordinary Dart
  layout (`BoxFit.cover`, `AspectRatio`). **This structurally eliminates the CENTER_CROP / zero-bounds
  / contentMode / dispose-race bug family** — there is no native contentMode fighting Flutter layout,
  and no per-view MethodChannel to tear down mid-dispose. It is the Impeller-recommended path and what
  every maintained Flutter video/animation plugin (`video_player`, `fvp`, `pag-flutter`) uses.
- **KTD-1a — Zero client-level boxing/centering; identical sizing on both platforms (hard requirement).**
  The package composites the `vapc` `rgbFrame` content region into a texture whose pixel dimensions are the
  **content aspect** (e.g. 1000×1000 square, 1504×846 for gunmetal) — **identically on iOS and Android**
  (both produce the same `Texture`; iOS no longer discards `fit`). Therefore the onboarding screens use a
  **single, platform-agnostic** `NeoVapView(..., fit: BoxFit.contain)` inside a normal box, with **no
  `Platform.isIOS` branch, no `Transform.scale`, no per-platform centering** at the client. All sizing is
  package-internal (the shader crop) or ordinary Flutter layout. The current `Transform.scale(2.3)` /
  duplicated-VapView hacks are deleted and never reappear (guarded in U6/U7).
- **KTD-2 — Decode ordinary video + shader-composite alpha; do NOT ask the OS for "alpha video".**
  The mp4 stays an ordinary H.264 side-by-side (RGB half + alpha half). A fragment shader samples both
  halves → premultiplied RGBA. This dodges the still-unsolved iOS-HEVC-alpha / Android-VP9-alpha codec
  split entirely (one universal encode, every device hardware-decodes it) and **plays existing VAP
  assets with zero transcode**.
- **KTD-3 — Back it with OS media stacks, not the Tencent VAP SDK.** iOS `AVPlayer` +
  `AVPlayerItemVideoOutput` → `CVPixelBuffer` (VideoToolbox HW decode); Android ExoPlayer/Media3 (or
  `MediaCodec`) → `SurfaceTexture`. Apple/Google maintain the decoders; neo_vap owns only the shader +
  texture plumbing (small, stable). `Tencent/vap` is officially maintenance-free — wrapping it is the
  highest-maintenance option disguised as the easiest.
- **KTD-4 — Evaluate `fvp` (libmdk) before writing native code.** `fvp` is maintained, texture-based,
  Impeller-friendly, hardware-decoding, a thin `video_player`-interface wrapper, and claims transparent
  HEVC/VP9. If it can render our content (with a side-by-side compositing hook, or from a transcoded
  true-alpha asset) it shortcuts most native work. Spike it first (U1); only build the native texture
  layer (U3/U4) if fvp can't do the side-by-side layout.
- **KTD-5 — Keep the side-by-side asset layout.** Per KTD-2 it needs no transcode and avoids the codec
  split. Transcoding to true HEVC-alpha/VP9-alpha (the fvp-direct path) re-introduces the platform
  split and a finicky encode (a quick VP9-alpha transcode test dropped the alpha channel), so it is the
  fallback, not the default.
- **KTD-6 — Bake in cold-start prewarm from day one** (the iOS pain fix): one persistent reused
  player+texture (never construct per-play), a warm decoder, `preroll`(iOS)/`prepare`(Android) the next
  clip while the current plays, and a 1-frame invisible warmup asset at app init to force Metal
  pipeline-state compile + decoder allocation before the first real animation.
- **KTD-7 — Looping in Dart/native player control, single sentinel.** No VAP-style side-by-side native
  loop quirk. One Dart "infinite" constant; the player seeks-to-0 on end (both platforms). Intro→loop is
  a two-clip sequence the controller chains. (Carries the fork lesson without the QGVAPlayer `-1` vs
  `Int.MAX` split, which was a QGVAPlayer artifact that no longer applies.)
- **KTD-8 — Separate repo, single package, living at `~/code/neosapien/neo_vap/`** (sibling to `neo/`,
  exactly like `../neo_ble`). Own `NeoSapien-xyz/neo_vap` GitHub repo; app depends via git URL + tag for
  releases (the `neo_ble` model), with a **local `path: ../neo_vap` (or `dependency_overrides`) during
  active dev** for fast iteration before the first tag. Single package (one folder: `lib/` + `android/` +
  `ios/`), not federated — federation is overkill unless web/multiple implementations are planned.

---

## High-Level Technical Design

```
  assets/animations/videos/*_vap.mp4   (ordinary H.264 side-by-side: RGB half + alpha half; unchanged)
            │
            ▼
   OS hardware video decoder                         ← Apple/Google maintain; not neo's code
   iOS:  AVPlayer + AVPlayerItemVideoOutput ──► CVPixelBuffer   (VideoToolbox)
   Android: ExoPlayer/Media3 (or MediaCodec) ─► SurfaceTexture  (MediaCodec)
            │
            ▼
   alpha-composite fragment shader                   ← neo_vap owns this (tiny)
   sample RGB region + alpha region (per vapc rgbFrame/aFrame) → premultiplied RGBA
   iOS: Metal   Android: GLES/Impeller
            │
            ▼
   Flutter-registered Texture (TextureRegistry)      ← repaints on frame arrival, no Dart per-frame
            │
            ▼
   NeoVapView = Texture widget, sized by BoxFit.cover / AspectRatio in Dart
   (no native contentMode → no CENTER_CROP/zero-bounds/scale races)
```

Loop / lifecycle (controller, Dart-side):
```
 onCreate ─► prewarm (warm decoder + PSO) ─► play(intro) ─► onEnd ─► play(loop, repeat=∞)
                                                   │
 dispose ─► release texture + player (no per-view MethodChannel → no MissingPluginException)
```

---

## Native Feasibility (layman) — verdict: build it, both platforms

Two per-platform deep-dives confirmed the texture architecture is **well-trodden, not research** — every
stage has shipping prior art (Tencent VAP, ByteDance AlphaPlayer, `fvp`/libmdk, `pag-flutter`, official
`video_player`). Plain-language summary:

**The pipeline, in one line:** the OS decodes the ordinary mp4 → each frame lands on the GPU → a ~10-line
shader mixes "color region + mask region" into a see-through frame → Flutter draws it as a normal `Texture`
widget. Only the last hop (handing the frame to Flutter instead of a native view) differs from a stock VAP
player, and `fvp`/`pag-flutter` already prove that hop works.

**iOS — YES / caveats.** Components: `AVPlayer` + `AVPlayerItemVideoOutput` (pull decoded frames) →
`CVPixelBuffer` in shared memory → `CVMetalTextureCache` (zero-copy onto the GPU) → Metal fragment shader
→ hand back via the `FlutterTexture` protocol (`copyPixelBuffer`) + `FlutterTextureRegistry`. Hard rules:
shader output **must be `kCVPixelFormatType_32BGRA`** (any other format renders as garbage/4-up) and must
**premultiply** (`rgb*alpha`, else edge halos). Recycle output buffers via a `CVPixelBufferPool`; pace with
`CADisplayLink` + `hasNewPixelBuffer`. All APIs are far below neo's iOS min. **The one real unknown:
Impeller external-texture behavior on neo's exact Flutter version → verify on a physical iPhone first.**

**Android — YES / caveats.** Decoder = **ExoPlayer / AndroidX Media3** (not raw MediaCodec — Google
maintains the decode/loop/preload loop). Frames land in a `SurfaceTexture` (external OES texture) → GL
shader composites → **hand to Flutter via `TextureRegistry.SurfaceProducer`, NOT the old
`SurfaceTextureEntry`** (which is a dead end on Impeller's Vulkan backend, API 29+; SurfaceProducer's
ImageReader/HardwareBuffer backend is the supported path). Hard rules: premultiply `vec4(rgb*a, a)`; apply
`SurfaceTexture.getTransformMatrix()`; use the `vapc` rects for crop; **one hardware decoder at a time**
(low-end phones allow only 2–3; release promptly or wedge the codec). **Impeller risk = MEDIUM, trending
down:** old SurfaceTexture crashes are avoided by SurfaceProducer; residual is stutter on cheap phones
(open issue #180831) but our single centered clip is the mild case, not the scrolling-feed pathology.
Fallback ladder: one-line `ImpellerBackend=opengles` manifest override → Skia → Hybrid Composition (last
resort); gate behind a remote-config kill-switch so a bad device-class can be downgraded without an app update.

**Deliberate alternative noted:** Apple ships native HEVC-with-alpha (true alpha channel, no shader) — simpler
on iOS but doesn't cross-play to Android from one asset. Kept as a considered-and-rejected option (KTD-2/5
keep one universal side-by-side asset instead).

---

## Output Structure

```
packages/neo_vap/
  pubspec.yaml
  lib/
    neo_vap.dart                 # public: NeoVapView widget + NeoVapController + events
    src/
      neo_vap_controller.dart    # play/loop/intro-chain/prewarm, single loop sentinel
      neo_vap_view.dart          # Texture-backed widget, BoxFit sizing
      neo_vap_method_channel.dart# texture id alloc, play/stop/prewarm calls
      vapc.dart                  # parse vapc atom → rgbFrame/aFrame regions (drives the shader)
  ios/
    Classes/NeoVapPlugin.swift   # AVPlayerItemVideoOutput → CVMetalTextureCache → FlutterTexture
    Classes/AlphaComposite.metal # side-by-side → premultiplied RGBA
  android/
    src/main/kotlin/.../NeoVapPlugin.kt   # ExoPlayer/Media3 → SurfaceTexture → GL composite → SurfaceProducer
    src/main/.../alpha_composite.frag
  example/                       # standalone harness for both screens' clips
  test/                          # Dart unit + widget tests
```

---

## Implementation Units

### U1. fvp spike + asset-path decision (de-risk gate)

**Goal:** Decide fvp-direct vs custom-native before writing native code.
**Approach:** (a) Transcode one asset (e.g. `active_mode_intro_vap.mp4`) to true alpha — HEVC-alpha
(iOS) and VP9-alpha webm (Android) via ffmpeg, splitting rgbFrame/aFrame per the `vapc` atom and
`alphamerge` (note the naive VP9 encode dropped alpha; use `-auto-alt-ref 0` / verify `yuva420p` + a
composite-over-color check). (b) Wire `fvp` (`fvp.registerWith()`) + `video_player`, play the
transcoded asset on a real iOS + Android device; confirm transparency composites and sizing is correct.
(c) Assess whether fvp exposes a hook to composite the **side-by-side** layout directly (no transcode).
**Files:** `example/` throwaway; scratch transcodes (not committed).
Also run the **#1 empirical unknown both feasibility reports flagged**: confirm a Flutter external
`Texture` (fvp's, as a stand-in) renders correctly under **Impeller on neo's exact Flutter 3.41.4** on a
**physical iPhone AND a budget Android phone** before committing to the architecture.
**Decision output:** if fvp plays true-alpha cleanly on both platforms AND transcode is reliable →
consider fvp-direct (thinnest neo_vap, or none). If side-by-side must be kept or fvp falls short →
proceed to custom native (U3/U4). If Impeller external-texture is broken on 3.41.4 → note the
`ImpellerBackend=opengles` / Skia fallback before proceeding. Record the call in the plan.
**Test scenarios:** device playback of transcoded clip on iOS + Android; visual transparency over a
colored background; sizing under `BoxFit.cover` in a portrait box; Impeller texture-render sanity on both.
**Verification:** a documented go/no-go on fvp + Impeller-on-3.41.4 with device evidence (screenshots).

### U2. `neo_vap` package scaffold + Dart API surface

**Goal:** Create the plugin package and its public API (independent of decode backend).
**Files:** `packages/neo_vap/pubspec.yaml`, `lib/neo_vap.dart`, `lib/src/neo_vap_view.dart`,
`lib/src/neo_vap_controller.dart`, `lib/src/neo_vap_method_channel.dart`, `lib/src/vapc.dart`; add
`neo_vap: { path: packages/neo_vap }` to the app `pubspec.yaml`.
**Approach:** `NeoVapView({videoAsset, introAsset?, placeholderAsset, fit=BoxFit.cover, onEnd, onError})`
renders a `Texture(textureId)` sized by `fit`, with the placeholder image beneath via `AnimatedOpacity`
(event-driven, no timers). `NeoVapController` owns play/loop/intro-chain/prewarm and a single infinite
loop sentinel (KTD-7). `vapc.dart` parses the `vapc` atom for rgbFrame/aFrame (drives the shader / crop).
**Patterns to follow:** `neo_ble` package layout; existing `light_indicators_screen` event-driven
placeholder is the good pattern to generalize.
**Test scenarios:** `vapc.dart` parses a real asset's atom → correct rgbFrame/aFrame (Covers KTD-2);
controller intro→loop state machine (intro fires once, loop repeats, re-entry skips intro); event
mapping (end/error); placeholder opacity toggles on start/end/error, never on a timer.
**Files (test):** `packages/neo_vap/test/vapc_test.dart`, `.../neo_vap_controller_test.dart`.
**Verification:** `dart analyze` clean; unit tests green; widget builds against a fake texture backend.

### U3. iOS: decode → Metal alpha-composite → Flutter texture

**Goal:** Native iOS backend producing a composited RGBA texture.
**Dependencies:** U2 (and U1 if it selects custom-native).
**Files:** `packages/neo_vap/ios/Classes/NeoVapPlugin.swift`, `.../AlphaComposite.metal`, podspec.
**Approach:** `AVPlayer` + `AVPlayerItemVideoOutput` pulls `CVPixelBuffer`s (VideoToolbox HW decode);
`CVMetalTextureCache` wraps them zero-copy; `AlphaComposite.metal` samples the rgbFrame + aFrame regions →
**premultiplied** RGBA, output as **`kCVPixelFormatType_32BGRA`** (non-negotiable — other formats render
as garbage/4-up per flutter#147242), into a `CVPixelBufferPool`-recycled buffer returned via the
`FlutterTexture` protocol's `copyPixelBuffer`; drive frame pulls with `CADisplayLink` +
`hasNewPixelBuffer`, hold each `CVMetalTexture` until the GPU command buffer completes. Handle the `vapc`
`alphaScale` (alpha region often half-size) and pad-to-16 via the `vapc` rects, sampling texel centers.
Loop seamlessly via `AVPlayerLooper`/seek-to-0 on `AVPlayerItemDidPlayToEndTime`, keeping the last frame.
No `UiKitView`, no `contentMode`.
**Test scenarios:** device: plays + composites transparency; sizing correct under `BoxFit.cover`; loop
seamless (no black frame at boundary); dispose releases texture + player with no leak/crash; the exact
onboarding clips render proportionate (no `Transform.scale`).
**Verification:** both onboarding clips render transparent + correctly-sized on a physical iPhone.

### U4. Android: decode → GL alpha-composite → Flutter texture

**Goal:** Native Android backend, parity with U3.
**Dependencies:** U2.
**Files:** `packages/neo_vap/android/src/main/kotlin/.../NeoVapPlugin.kt`, `.../alpha_composite.frag`.
**Approach:** **AndroidX Media3 (ExoPlayer)** — not raw `MediaCodec` — decodes into a `SurfaceTexture`
(external OES); a GL shader (`alpha_composite.frag`) recombines rgbFrame + aFrame → **premultiplied**
`vec4(rgb*a, a)` and draws into the Surface from **`TextureRegistry.SurfaceProducer`** (NOT the legacy
`SurfaceTextureEntry`, which is dead on Impeller/Vulkan API 29+). Apply `SurfaceTexture.getTransformMatrix()`
to input UVs; crop via the `vapc` rects. Implement `SurfaceProducer.Callback` fully; re-acquire
`getSurface()` on `onSurfaceAvailable` (don't cache). **One hardware decoder at a time** (low-end phones
allow 2–3; release on dispose or wedge the codec). Loop via `REPEAT_MODE_ONE` or seek-to-0 on
frame-available. Ship Vulkan default; keep a one-line `ImpellerBackend=opengles` manifest override + a
remote-config kill-switch ready (per-device-class downgrade without an app update). Confirm within H.264
L4.0 (current assets are).
**Test scenarios:** device: transparency + sizing; seamless loop; dispose releases decoder + GL + producer
(no `errorType 10002` in logcat, no decoder-instance leak); both onboarding clips proportionate; **budget
phone: check #180831 stutter case**; Impeller Vulkan render correct (fallback path if not.)
**Verification:** both clips render transparent + correctly-sized on a physical Android device;
`adb logcat` clean of MediaCodec errors; no `MissingPluginException` on navigate-away.

### U5. Cold-start prewarm (the iOS latency fix)

**Goal:** First animation appears near-instantly; kill the few-seconds iOS delay.
**Dependencies:** U3, U4.
**Files:** iOS `NeoVapPlugin.swift`, Android `NeoVapPlugin.kt`, `lib/src/neo_vap_controller.dart`,
one call from app init (`main_init.dart`).
**Approach:** (1) `NeoVap.prewarm()` at app init: create Metal device + compile the composite pipeline
state + allocate a decoder via a 1-frame invisible warmup asset (iOS `dispatch_once`, background queue).
(2) Persistent reused player+texture — never construct per play. (3) `preroll`(iOS)/`prepare`(Android)
the next clip (e.g. loop) while the current (intro) plays. (4) Placeholder fades on the real
first-frame-rendered signal, not a timer.
**Test scenarios:** measure first-frame time cold vs warmed (target: sub-few-hundred-ms after prewarm);
placeholder hides only on real first frame; no double-init on rapid screen re-entry.
**Execution note:** verify first-frame latency on a physical iPhone before/after prewarm — this is the
primary success metric, not a unit test.
**Verification:** on-device iOS: onboarding video visible within a few hundred ms of screen open.

### U6. Migrate onboarding screens onto `NeoVapView`; delete the hack pile

**Goal:** Replace `flutter_vap_plus` usage with `neo_vap`; remove all workarounds.
**Dependencies:** U2 (+ U3/U4 or U1's fvp path).
**Files:** `lib/view/screens/onboarding/bluetooth_pairing_screen/bluetooth_pairing_screen_2.dart`,
`lib/view/screens/onboarding/light_indicators_screen/light_indicators_screen.dart`, `pubspec.yaml`
(remove `flutter_vap_plus` + dead commented `video_player` git block + orphan VAP comment).
**Approach:** Both screens use a single `NeoVapView` per animation, sized by ordinary layout. Delete:
`Transform.scale(2.3)`/`2.0`, the `Platform.isIOS`/`else` duplicated VapView, `_loadAssetPath`
temp-file copy, all `Future.delayed` placeholder timers, the `controller?.stop()` dispose loop
(the `MissingPluginException` source), and the `_isStartVideoPlayed`/`_showPlaceholder` bookkeeping
(now owned by the controller).
**Test scenarios:** widget tests for both screens render `NeoVapView`; no `Transform.scale`/`Platform`
branch remains; navigate-away disposes cleanly.
**Verification:** both onboarding screens visually correct on iOS + Android; grep confirms the removed
symbols are gone.

### U7. Example app, tests, regression guards

**Goal:** Standalone harness + durable tests.
**Dependencies:** U2–U5.
**Files:** `packages/neo_vap/example/`, `packages/neo_vap/test/*`.
**Approach:** Example plays all five onboarding clips (intro+loop, sizing, prewarm). Dart tests cover
`vapc` parsing, controller state machine, event/placeholder logic. Regression guard: a test that fails
if a per-view `stop()`-in-dispose pattern is reintroduced (carries the NEO-1731 lesson) — or, given the
texture architecture removes that seam, a guard asserting dispose releases the texture id.
**Test scenarios:** enumerated above per unit; example runs on both platforms.
**Verification:** `fvm flutter test` green; example runs on both devices.

---

## Scope Boundaries

**In scope:** texture-based `neo_vap` plugin (iOS+Android), side-by-side alpha shader, cold-start
prewarm, onboarding migration, removal of `flutter_vap_plus` + hacks, tests + example.

**Deferred to Follow-Up Work:**
- Graduate `packages/neo_vap` → `NeoSapien-xyz/neo_vap` git-tagged repo (neo_ble model) once API stabilizes.
- VAPX-style dynamic text/avatar overlay (not needed — onboarding assets are static).
- Re-author gunmetal asset tightly-framed via VapTool (cosmetic; `BoxFit.cover` + texture sizing largely resolves it).
- Web support (Tencent VAP has web; not needed for the app).

**Outside this product's identity:**
- Migrating to PAG/libpag (re-author from After Effects) — strongest 2026 format for *new* complex
  effects, but overkill for playing existing static clips. Revisit only for a net-new effects catalog.
- Adopting SVGA (5-property vector envelope; can't do VAP-grade video effects).

---

## Risks & Mitigations

- **Native texture work is non-trivial (Metal/GL).** Mitigation: U1 fvp spike may shortcut most of it;
  the shader is small and well-trodden (AlphaPlayer/Archibald prior art).
- **Impeller external-texture on neo's Flutter 3.41.4 — the #1 empirical unknown (both platforms).**
  Mitigation: U1 verifies it on a physical iPhone + budget Android before any native code. Android residual
  = stutter on cheap phones (open #180831), but our single centered clip is the mild case, not the
  scrolling-feed pathology; use `SurfaceProducer` (avoids the closed #145077 crash class). Fallback ladder:
  `ImpellerBackend=opengles` (one line) → Skia → Hybrid Composition (last resort), gated by a remote-config
  kill-switch. iOS uses the clean Metal/CVPixelBuffer path.
- **fvp true-alpha transcode is finicky** (VP9 alpha dropped in a quick test). Mitigation: this is why
  side-by-side + custom shader (KTD-5) is the default; transcode is only the fvp-direct fallback.
- **Scope is a full plugin build.** Mitigation: sequence U1 gate first; each unit lands independently;
  onboarding keeps working on `flutter_vap_plus` until U6 flips it.

---

## Verification (end-to-end)

1. `fvm flutter analyze` + `fvm flutter test` green (plugin + app).
2. **iOS device:** both onboarding screens — video transparent, correctly sized (no scale hack),
   loops seamlessly, **first frame within a few hundred ms of screen open** (prewarm), no
   `MissingPluginException` on navigate-away.
3. **Android device:** same; `adb logcat` clean of MediaCodec `errorType 10002`.
4. Grep: `Transform.scale`, `Platform.isIOS` VAP branch, `_loadAssetPath`, `flutter_vap_plus` all gone
   from the onboarding screens + pubspec.
5. Example app plays all five clips on both platforms.

---

## Build method — compound-engineering

**Package bootstrap (run in `~/code/neosapien/`, sibling to `neo/`):**

```bash
cd ~/code/neosapien
flutter create --org xyz.neosapien --template=plugin --platforms=android,ios \
  -i swift -a kotlin \
  --description "Texture-based transparent (alpha) VAP video player for Flutter" \
  neo_vap
```

(Global flutter is 3.41.4 = neo's version; add a `.fvmrc` pinning `3.41.4` to the new package after.)
Then: `git init` + create `NeoSapien-xyz/neo_vap` on GitHub; in the app `pubspec.yaml` depend via
`neo_vap: { path: ../neo_vap }` during dev, switch to `git: { url, ref: v0.0.1 }` for releases (neo_ble
model). Copy this plan into `neo_vap/docs/plans/2026-07-11-001-feat-neo-vap-plugin-plan.md` so `ce-work`
consumes it in-repo.

**Build the package via compound-engineering.** This plan is a `ce-plan` artifact
(`artifact_contract: ce-unified-plan/v1`, `implementation-ready`); drive implementation with **`ce-work`**
against it, unit by unit in dependency order (U1 gate → U2 → U3/U4 → U5 → U6 → U7), running each unit's
Verification Contract + test scenarios before moving on. Capture durable learnings with `ce-compound` as
they surface (e.g. the Impeller-on-3.41.4 result, premultiply/BGRA gotchas).

Because units U3 (Swift+Metal) and U4 (Kotlin+GLES) are independent per-platform work, they may be fanned
out in parallel (the "ultracode"/Workflow path the user allowed) while Dart U2/U5 proceed alongside; U1's
device gate runs first, on-device verification runs serially. Orchestration is an execution choice for
`ce-work`; kept out of the unit definitions.

---

## Sources & Research
- Industry convergence (VAP/AlphaPlayer/stacked-alpha), Texture vs PlatformView, cold-start prewarm:
  Tencent/vap, bytedance/AlphaPlayer, Tencent/libpag + libpag/pag-flutter, jakearchibald.com
  "Video with transparency", Flutter Texture/PlatformView docs, flutter#180831/#145077,
  fvp/libmdk (pub.dev + wang-bin/fvp), Apple `preroll`, Media3 PreloadManager. (Full URLs in session research.)
- Fork harvest (both user forks): iOS CENTER_CROP frame-math, loop sentinel, playAsset, "3 root causes",
  prewarm — most of which the texture architecture makes moot, prewarm being the durable carry-over.
- Decode limits: current assets h264 Main L4.0 (5,922 / 7,520 MB-frame) within Android's 8,192 cap.
