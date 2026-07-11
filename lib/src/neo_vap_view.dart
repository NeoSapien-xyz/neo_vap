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
  final String? placeholderAsset;

  final BoxFit fit;

  /// Content aspect ratio (width / height). When known, [fit] is applied
  /// against it; otherwise the texture fills the box.
  // ponytail: caller-supplied for now; the native backend will report the
  // real vapc aspect on init so this becomes optional-then-authoritative.
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

  Widget _buildTexture(int textureId) {
    final texture = Texture(textureId: textureId);
    final ar = widget.aspectRatio;
    if (ar == null) return texture;
    return FittedBox(
      fit: widget.fit,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: ar,
        height: 1,
        child: texture,
      ),
    );
  }
}
