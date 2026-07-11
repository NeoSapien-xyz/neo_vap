/// Texture-based transparent (alpha) VAP video player for Flutter.
///
/// Decodes an ordinary side-by-side H.264 clip with the OS video decoder and
/// composites the alpha in a GPU shader into a Flutter [Texture] — no
/// PlatformView, so no CENTER_CROP / zero-bounds / dispose-race bugs.
library;

export 'src/neo_vap_controller.dart' show NeoVap, NeoVapController, NeoVapState;
export 'src/neo_vap_view.dart' show NeoVapView;
export 'src/vapc.dart' show VapcInfo, VapcRect, VapcParseException;

// The backend seam (NeoVapBackend / MethodChannelNeoVap / NeoVapEvent / loop
// sentinels) is deliberately NOT exported — it is an internal contract for the
// native backends and tests, not public API. Tests import 'src/...' directly.
