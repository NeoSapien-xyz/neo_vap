import 'dart:async';

import 'package:flutter/foundation.dart';

import 'neo_vap_method_channel.dart';

/// Playback lifecycle states.
enum NeoVapState {
  /// Constructed, no texture allocated yet.
  idle,

  /// [NeoVapController.initialize] is allocating the texture.
  initializing,

  /// Texture allocated, not yet playing.
  ready,

  /// The one-shot intro clip is playing.
  playingIntro,

  /// The loop is playing (infinite unless a finite repeat was requested).
  playingLoop,

  /// A finite play completed. Only reachable when the loop is not infinite;
  /// an intro→infinite-loop sequence never reaches this state.
  ended,

  /// A native playback/allocation error occurred; the placeholder is re-shown.
  error,

  /// Disposed; the texture is released and no further state changes occur.
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
    @visibleForTesting NeoVapBackend? backend,
    this.onEnd,
    this.onError,
    this.onFirstFrame,
  }) : _backend = backend ?? _sharedBackend;

  /// One backend for the whole app: a single [MethodChannelNeoVap] means a
  /// single native EventChannel subscription, so a disposing controller's
  /// stream-cancel never nulls the shared native event sink out from under a
  /// freshly-created controller (the intro→loop event-drop race). Events are
  /// demuxed per controller by texture id in [_onEvent].
  static final NeoVapBackend _sharedBackend = MethodChannelNeoVap();

  /// The backend this controller uses. Exposed only so tests can assert the
  /// shared-backend invariant.
  @visibleForTesting
  NeoVapBackend get backend => _backend;

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
      final id = await _backend.allocateTexture();
      if (_state == NeoVapState.disposed) return; // disposed mid-allocation
      _textureId = id;
      _setState(NeoVapState.ready);
    } catch (e) {
      _fail('initialize failed: $e');
    }
  }

  /// Start (or restart) playback. Plays the intro once the first time, then the
  /// loop; on any later call the intro is skipped and the loop plays directly.
  Future<void> play() async {
    if (_textureId == null || _state == NeoVapState.disposed) return;
    try {
      if (_hasIntro && !_introPlayed) {
        _setState(NeoVapState.playingIntro);
        // Preroll the loop while the intro plays so the handoff is seamless.
        // A preroll failure is non-fatal — the loop still starts on its own.
        unawaited(_backend.prepare(_textureId!, videoAsset).catchError((_) {}));
        await _backend.play(_textureId!, introAsset!, repeat: kNeoVapPlayOnce);
      } else {
        await _playLoop();
      }
    } catch (e) {
      _fail('play failed: $e');
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
          // Chain intro → loop; surface a start failure instead of dropping it.
          _playLoop().catchError((Object e) => _fail('play failed: $e'));
        } else if (_state == NeoVapState.playingLoop) {
          _setState(NeoVapState.ended);
          onEnd?.call();
        }
        // A stale 'ended' while not actively playing (e.g. after stop()) is
        // ignored — it must not resurrect playback or misfire onEnd.
      case NeoVapEventType.error:
        _fail(event.message ?? 'unknown playback error');
    }
  }

  void _fail(String message) {
    if (_state == NeoVapState.disposed) return;
    _showPlaceholder = true;
    _setState(NeoVapState.error);
    onError?.call(message);
  }

  void _setState(NeoVapState next) {
    if (_state == NeoVapState.disposed) return; // never notify after dispose
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
