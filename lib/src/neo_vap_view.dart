import 'package:flutter/widgets.dart';

import 'neo_vap_controller.dart';

/// Plays a transparent (alpha) VAP animation into a Flutter [Texture].
///
/// Sizing is ordinary Dart layout — [fit] applied against the clip's content
/// aspect ([aspectRatio]) — identically on iOS and Android. There is no
/// `Platform.isIOS` branch and no `Transform.scale` here or at the call site.
///
/// A [placeholderAsset] image sits above the texture and fades out on the first
/// rendered frame (event-driven, never a timer), then fades back in on error.
///
/// The view reads [videoAsset]/[controller] once, in `initState`. To play a
/// different clip or swap controllers, give the view a new [Key] so it is
/// recreated — changing these props on an existing element has no effect.
class NeoVapView extends StatefulWidget {
  const NeoVapView({
    super.key,
    required this.videoAsset,
    this.introAsset,
    this.placeholderAsset,
    this.fit = BoxFit.cover,
    this.aspectRatio,
    this.controller,
    this.onEnd,
    this.onError,
    this.placeholderFadeDuration = const Duration(milliseconds: 200),
  }) : assert(
          controller == null || (onEnd == null && onError == null),
          'With an external controller, wire onEnd/onError on the controller '
          'itself — the view ignores its own callbacks (and videoAsset/'
          'introAsset) when a controller is supplied.',
        );

  /// The looping clip asset key. Ignored when [controller] is supplied.
  final String videoAsset;

  /// Optional one-shot intro played once before the loop.
  final String? introAsset;

  /// Optional image shown until the first frame renders.
  ///
  /// Deliberately unused by the neo onboarding screens: in practice the
  /// hand-off flashes. The still and the first decoded frame do not land on the
  /// same pixels at the same moment — the fade runs on `firstFrame`, which fires
  /// when the texture has a frame, not when the compositor has presented it — so
  /// the swap reads as a visible blink rather than a seamless reveal. It has
  /// been added and reverted more than once (neo 65359db5, 9ccb7fd7, 83e62df9).
  ///
  /// The blank window it was meant to hide is real (~420ms cold start on a
  /// mid-range device), but a flash is worse than a wait. Fix the cold start
  /// instead — keep the controller alive across rebuilds so the texture is never
  /// torn down. Do not reach for this again without solving the flash first.
  final String? placeholderAsset;

  final BoxFit fit;

  /// Overrides the content aspect ratio (width / height). Normally null — the
  /// native backend reports the real `vapc` aspect on init and the view sizes
  /// against that. Set this only to force a different aspect (e.g. crop past
  /// transparent margins with [BoxFit.cover]); an explicit value wins over the
  /// reported one.
  final double? aspectRatio;

  /// Optional externally-owned controller. When null, the view creates and owns
  /// one from [videoAsset]/[introAsset]/[onEnd]/[onError] (and disposes it).
  /// When provided, the caller owns its lifecycle and those props are ignored —
  /// configure playback and callbacks on the controller instead.
  final NeoVapController? controller;

  final VoidCallback? onEnd;
  final void Function(String message)? onError;

  final Duration placeholderFadeDuration;

  @override
  State<NeoVapView> createState() => _NeoVapViewState();
}

class _NeoVapViewState extends State<NeoVapView> {
  NeoVapController? _internalController;
  NeoVapController get _controller => widget.controller ?? _internalController!;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _internalController = NeoVapController(
        videoAsset: widget.videoAsset,
        introAsset: widget.introAsset,
        onEnd: widget.onEnd,
        onError: widget.onError,
      );
    }
    _controller.addListener(_onControllerChanged);
    _start();
  }

  Future<void> _start() async {
    await _controller.initialize();
    if (!mounted) return;
    await _controller.play();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    // Only dispose the controller we created; a caller-supplied one is theirs.
    _internalController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textureId = _controller.textureId;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (textureId != null) _buildTexture(textureId),
        if (widget.placeholderAsset != null)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _controller.showPlaceholder ? 1.0 : 0.0,
                duration: widget.placeholderFadeDuration,
                child: Image.asset(
                  widget.placeholderAsset!,
                  fit: widget.fit,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Height of the aspect box handed to [FittedBox]. Only the ratio matters —
  /// this just keeps both dimensions far from the sub-pixel truncation floor.
  static const double _aspectBoxHeight = 1000;

  Widget _buildTexture(int textureId) {
    final texture = Texture(textureId: textureId);
    // Explicit override wins; otherwise use the aspect native reported on init.
    final ar = widget.aspectRatio ?? _controller.contentAspect;
    if (ar == null) return texture;
    return FittedBox(
      fit: widget.fit,
      clipBehavior: Clip.hardEdge,
      // Scaled, not a unit box: FittedBox only scales the child's *painting*, so
      // this SizedBox's literal layout size is what Flutter hands the texture
      // layer. At width: ar, height: 1 a portrait clip (ar < 1) truncates to a
      // 0-wide texture descriptor in Impeller's GLES path and every frame is
      // silently dropped. Any non-degenerate size with the same ratio works.
      child: SizedBox(
        width: ar * _aspectBoxHeight,
        height: _aspectBoxHeight,
        child: texture,
      ),
    );
  }
}
