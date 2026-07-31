## 0.1.2

Teardown and error-handling hardening — turns three silent failure modes into
survivable ones. Found by an adversarial review of the shipping app.

* **Android: `catch (Throwable)` instead of `catch (Exception)`** in
  `NeoVapPlugin.onMethodCall`. An `OutOfMemoryError`/`UnsatisfiedLinkError`
  during `allocateTexture`/`play` (which start a HandlerThread and build an
  ExoPlayer) was escaping the plugin's own error handler, making the engine send
  an empty reply that Dart raised as `MissingPluginException` — the exact failure
  the texture architecture exists to prevent. Now surfaced as a clean
  `PlatformException` the controller already downgrades to a recoverable state.
* **Dart: `stop()` and `dispose()` no longer leak async rejections.** Both are
  called unawaited on teardown paths (a page swipe stops the off-screen
  controller; `dispose()` fires and forgets), so an escaping rejection had no
  caller left to observe it and landed as an unhandled async error — a
  Crashlytics non-fatal on every occurrence in an app that forwards zone errors.
  `stop()` now routes failures to `onError` without latching a render error;
  `dispose()` swallows the release rejection.
* **Android: GL-init failure no longer orphans a render thread.** If
  `awaitInputSurface()` threw (GL init failure/3s timeout), the half-built
  `NeoVapRenderer` — HandlerThread + EGL already up — was never assigned to the
  player, so `dispose()` could never reclaim it. It is now released before the
  error propagates.
* Tests: a `RejectingBackend` that throws `MissingPluginException` from
  teardown (a `FakeBackend` whose methods cannot throw could not catch the
  missing guards), and a source-parity test asserting every method Dart sends is
  handled by both native switches.

## 0.1.1

No plugin code change. `v0.1.0` was tagged one commit before `main`, so the tag
excluded the example app's lockfile sync. This retag makes the tag and `main`
the same tree, so a consumer pinning the tag gets exactly what `main` holds.

## 0.1.0

First tagged release. Texture-based transparent (alpha) VAP video playback on
both platforms, device-verified.

* Android backend: ExoPlayer/Media3 decode, OpenGL ES alpha composite, rendered
  into a `TextureRegistry.SurfaceProducer`.
* iOS backend: `AVQueuePlayer` decode, Metal composite, rendered into a
  `FlutterTexture`.
* Gapless intro-to-loop and seamless looping on both platforms.
* Native reports the clip's content aspect, so the view sizes itself off the
  real `vapc` geometry instead of a hardcoded ratio.
* `NeoVap.prewarm()` warms the composite pipeline once per process to cut
  cold-start latency.
* Fixed: a portrait clip rendered blank on Impeller's OpenGLES backend. The
  aspect box handed to `FittedBox` was sub-pixel, so the external texture
  descriptor truncated to zero width and every frame was discarded.
* Fixed: `firstFrame` fired on the bind-time redraw of an empty texture,
  before the decoder had delivered anything.

Repository moved to the `NeoSapien-xyz` organisation. Update any git dependency
pointing at the old URL.

Not published to pub.dev. Install by git ref.

## 0.0.1

Untagged initial development version.
