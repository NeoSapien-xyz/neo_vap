import 'dart:async';

import 'package:flutter/foundation.dart';

import 'neo_vap_method_channel.dart';

/// Playback lifecycle states.
enum NeoVapState {
  idle,
  initializing,
  ready,
  playingIntro,
  playingLoop,
  ended,
  error,
  disposed,
}

/// Owns a single reusable texture + player for one animation and drives the
/// intro→loop sequence (KTD-7). The controller is the unit of playback state;
/// screens hold one and hand it to a [NeoVapView].
///
/// The placeholder is shown until the real first frame renders and re-shown on
/// error — driven entirely by native events, never a timer (KTD-6 / the
/// light_indicators_screen lesson).
class NeoVapController extends ChangeNotifier {
  NeoVapController({
    required this.videoAsset,
    this.introAsset,
    NeoVapBackend? backend,
    this.onEnd,
    this.onError,
    this.onFirstFrame,
  }) : _backend = backend ?? MethodChannelNeoVap();

  /// The looping clip.
  final String videoAsset;

  /// Optional one-shot intro played once before the loop.
  final String? introAsset;

  final NeoVapBackend _backend;

  /// Fires when a finite play completes with nothing left to chain. Never fires
  /// for an infinite loop.
  final VoidCallback? onEnd;

  /// Fires on a native playback error, with the error message.
  final void Function(String message)? onError;

  /// Fires when the first real frame renders (placeholder can be removed).
  final VoidCallback? onFirstFrame;

  int? _textureId;
  NeoVapState _state = NeoVapState.idle;
  bool _introPlayed = false;
  bool _showPlaceholder = true;
  StreamSubscription<NeoVapEvent>? _sub;

  /// Registered texture id, or null before [initialize].
  int? get textureId => _textureId;

  NeoVapState get state => _state;

  /// Whether the placeholder should be visible (true until first frame).
  bool get showPlaceholder => _showPlaceholder;

  bool get _hasIntro => introAsset != null;

  /// Allocate the texture and subscribe to native events. Idempotent.
  Future<void> initialize() async {
    if (_state != NeoVapState.idle) return;
    _setState(NeoVapState.initializing);
    _sub = _backend.events.listen(_onEvent);
    try {
      _textureId = await _backend.allocateTexture();
      _setState(NeoVapState.ready);
    } catch (e) {
      _fail('initialize failed: $e');
    }
  }

  /// Start (or restart) playback. Plays the intro once the first time, then the
  /// loop; on any later call the intro is skipped and the loop plays directly.
  Future<void> play() async {
    if (_textureId == null || _state == NeoVapState.disposed) return;
    if (_hasIntro && !_introPlayed) {
      _setState(NeoVapState.playingIntro);
      // Preroll the loop while the intro plays so the handoff is seamless.
      unawaited(_backend.prepare(_textureId!, videoAsset));
      await _backend.play(_textureId!, introAsset!, repeat: kNeoVapPlayOnce);
    } else {
      await _playLoop();
    }
  }

  Future<void> _playLoop() async {
    _introPlayed = true;
    _setState(NeoVapState.playingLoop);
    await _backend.play(_textureId!, videoAsset, repeat: kNeoVapLoopForever);
  }

  /// Stop playback and re-show the placeholder.
  Future<void> stop() async {
    if (_textureId == null) return;
    await _backend.stop(_textureId!);
    _showPlaceholder = true;
    _setState(NeoVapState.ready);
  }

  void _onEvent(NeoVapEvent event) {
    if (event.textureId != _textureId || _state == NeoVapState.disposed) return;
    switch (event.type) {
      case NeoVapEventType.firstFrame:
        _showPlaceholder = false;
        notifyListeners();
        onFirstFrame?.call();
      case NeoVapEventType.ended:
        if (_state == NeoVapState.playingIntro) {
          _playLoop(); // chain intro → loop
        } else {
          _setState(NeoVapState.ended);
          onEnd?.call();
        }
      case NeoVapEventType.error:
        _fail(event.message ?? 'unknown playback error');
    }
  }

  void _fail(String message) {
    _showPlaceholder = true;
    _setState(NeoVapState.error);
    onError?.call(message);
  }

  void _setState(NeoVapState next) {
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    final id = _textureId;
    if (id != null) {
      // Fire-and-forget: releasing the texture must not block widget teardown,
      // and there is no per-view MethodChannel to raise MissingPluginException.
      unawaited(_backend.dispose(id));
    }
    _textureId = null;
    _state = NeoVapState.disposed;
    super.dispose();
  }
}
