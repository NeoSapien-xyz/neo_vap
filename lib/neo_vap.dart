/// Texture-based transparent (alpha) VAP video player for Flutter.
///
/// Decodes an ordinary side-by-side H.264 clip with the OS video decoder and
/// composites the alpha in a GPU shader into a Flutter [Texture] — no
/// PlatformView, so no CENTER_CROP / zero-bounds / dispose-race bugs.
library;

export 'src/neo_vap_controller.dart' show NeoVapController, NeoVapState;
export 'src/neo_vap_method_channel.dart'
    show
        NeoVapBackend,
        MethodChannelNeoVap,
        NeoVapEvent,
        NeoVapEventType,
        kNeoVapLoopForever,
        kNeoVapPlayOnce;
export 'src/neo_vap_view.dart' show NeoVapView;
export 'src/vapc.dart' show VapcInfo, VapcRect, VapcParseException;
