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

  /// Playing — the intro→loop sequence (chained gaplessly by the native player)
  /// or a standalone clip. Infinite unless a finite repeat was requested.
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
/// intro→loop sequence. The controller is the unit of playback state; screens
/// hold one and hand it to a [NeoVapView].
///
/// The placeholder shows until the first real frame renders and re-shows on
/// error — driven by native events, never a timer.
class NeoVapController extends ChangeNotifier {
  NeoVapController({
    required this.videoAsset,
    this.introAsset,
    @visibleForTesting NeoVapBackend? backend,
    this.onEnd,
    this.onError,
    this.onFirstFrame,
  }) : _backend = backend ?? _sharedBackend;

  /// One shared backend for the whole app — a single EventChannel subscription,
  /// so a disposing controller's stream-cancel can't null the native sink out
  /// from under a freshly-created one (the intro→loop event-drop race). Events
  /// are demuxed per controller by texture id in [_onEvent].
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
  double? _contentAspect;
  StreamSubscription<NeoVapEvent>? _sub;

  /// Registered texture id, or null before [initialize].
  int? get textureId => _textureId;

  NeoVapState get state => _state;

  /// The clip's real content aspect (width / height), reported by native on the
  /// first play, or null until then. [NeoVapView] uses this so callers no longer
  /// have to hardcode an aspect.
  double? get contentAspect => _contentAspect;

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
        _introPlayed = true;
        _setState(NeoVapState.playingLoop);
        // Native plays the intro once then loops the clip forever, gaplessly —
        // no 'ended' round-trip, so a dropped event can't strand the loop.
        await _backend.play(
          _textureId!,
          introAsset!,
          repeat: kNeoVapPlayOnce,
          nextAsset: videoAsset,
        );
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
    try {
      await _backend.stop(_textureId!);
    } catch (e) {
      // Callers stop unawaited on teardown paths (a page swipe stops the
      // off-screen controller), so an escaping rejection lands as an unhandled
      // async error. Report it, but do not latch NeoVapState.error: a failed
      // stop is not a render failure, and the local intent — placeholder up,
      // controller still usable — holds whether or not native acknowledged.
      onError?.call('stop failed: $e');
    }
    _showPlaceholder = true;
    _setState(NeoVapState.ready);
  }

  void _onEvent(NeoVapEvent event) {
    if (event.textureId != _textureId || _state == NeoVapState.disposed) return;
    switch (event.type) {
      case NeoVapEventType.info:
        final w = event.width, h = event.height;
        // Guard both dims: a numeric-but-nonsensical payload ("0x846", negatives)
        // passes int.tryParse; a 0/negative aspect would collapse the view, so
        // ignore it and leave the caller-supplied aspect in force.
        if (w != null && h != null && w > 0 && h > 0) {
          _contentAspect = w / h;
          notifyListeners();
        }
      case NeoVapEventType.firstFrame:
        _showPlaceholder = false;
        notifyListeners();
        onFirstFrame?.call();
      case NeoVapEventType.ended:
        // Intro→loop never ends natively, so 'ended' means a finite play truly
        // finished. Gated on playingLoop so a stale event after stop() can't
        // resurrect playback or misfire onEnd.
        if (_state == NeoVapState.playingLoop) {
          _setState(NeoVapState.ended);
          onEnd?.call();
        }
      case NeoVapEventType.error:
        _fail(event.message ?? 'unknown playback error');
    }
  }

  void _fail(String message) {
    if (_state == NeoVapState.disposed) return;
    _showPlaceholder = true;
    if (_textureId == null) {
      // Allocation never completed, so there is no texture to latch onto.
      // Reset to idle (dropping the event subscription initialize() will
      // re-create, to avoid a double-listen) so a later remount can retry,
      // instead of being stuck in a permanent error state. Playback failures
      // keep _textureId and still latch as error below.
      _sub?.cancel();
      _sub = null;
      _setState(NeoVapState.idle);
    } else {
      _setState(NeoVapState.error);
    }
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
      // Fire-and-forget: releasing the texture must not block widget teardown.
      //
      // The catchError is load-bearing. MissingPluginException comes from a null
      // platform reply, which happens on no registered handler, an uncaught
      // native throwable, or notImplemented() — channel topology rules out none
      // of them. What actually protects this plugin is method-name parity with
      // both native switches plus a single process-wide channel, and neither is
      // an invariant this line can rely on. Teardown is also the one path with
      // no caller left to observe a rejection, so swallow it here.
      unawaited(_backend.dispose(id).catchError((Object _) {}));
    }
    _textureId = null;
    _state = NeoVapState.disposed;
    super.dispose();
  }
}

/// App-level `neo_vap` entry points not tied to a single [NeoVapController].
class NeoVap {
  NeoVap._();

  /// Warm the native decode + composite pipeline once at app init so the first
  /// animation renders without the cold-start compile/allocate stall.
  /// Fire-and-forget; safe to call repeatedly — native warms once per process.
  static Future<void> prewarm({String? warmupAsset}) =>
      NeoVapController._sharedBackend
          .prewarm(warmupAsset: warmupAsset)
          // A platform with no native prewarm handler rejects with
          // MissingPluginException; swallow so this fire-and-forget call never
          // surfaces an unhandled async error. Native logs real warm failures.
          .catchError((Object _) {});
}
