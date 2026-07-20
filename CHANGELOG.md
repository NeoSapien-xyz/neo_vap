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
