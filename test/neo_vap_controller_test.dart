import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neo_vap/neo_vap.dart';
import 'package:neo_vap/src/neo_vap_method_channel.dart';

/// Records backend calls and lets tests inject native events.
class FakeBackend implements NeoVapBackend {
  final List<String> calls = [];
  final StreamController<NeoVapEvent> _events =
      StreamController<NeoVapEvent>.broadcast();
  int allocatedId = 42;
  bool failAllocate = false;

  @override
  Future<int> allocateTexture() async {
    calls.add('allocate');
    if (failAllocate) throw Exception('allocate boom');
    return allocatedId;
  }

  @override
  Future<void> prewarm({String? warmupAsset}) async => calls.add('prewarm');

  @override
  Future<void> play(
    int textureId,
    String asset, {
    int repeat = kNeoVapLoopForever,
    String? nextAsset,
  }) async =>
      calls.add(
        'play:$asset:repeat=$repeat${nextAsset != null ? ':next=$nextAsset' : ''}',
      );

  @override
  Future<void> stop(int textureId) async => calls.add('stop');

  @override
  Future<void> dispose(int textureId) async => calls.add('dispose');

  @override
  Stream<NeoVapEvent> get events => _events.stream;

  void emit(NeoVapEvent e) => _events.add(e);
  Future<void> close() => _events.close();
}

/// A backend whose teardown calls reject the way a real platform does when no
/// handler answers: the engine sends a null reply and Dart raises
/// [MissingPluginException]. [FakeBackend]'s methods can never throw, so on its
/// own it cannot catch an unguarded call — which is exactly how the missing
/// guards on `stop()`/`dispose()` survived a green suite.
class RejectingBackend extends FakeBackend {
  @override
  Future<void> stop(int textureId) async {
    calls.add('stop');
    throw MissingPluginException('No implementation found for method stop');
  }

  @override
  Future<void> dispose(int textureId) async {
    calls.add('dispose');
    throw MissingPluginException('No implementation found for method dispose');
  }
}

void main() {
  late FakeBackend backend;

  setUp(() => backend = FakeBackend());
  tearDown(() => backend.close());

  NeoVapController make({
    String? intro,
    void Function(String)? onError,
    void Function()? onEnd,
  }) =>
      NeoVapController(
        videoAsset: 'loop.mp4',
        introAsset: intro,
        backend: backend,
        onError: onError,
        onEnd: onEnd,
      );

  test('initialize allocates a texture and becomes ready', () async {
    final c = make();
    await c.initialize();
    expect(c.textureId, 42);
    expect(c.state, NeoVapState.ready);
    expect(backend.calls, contains('allocate'));
  });

  test('intro→loop is one gapless native call (no ended round-trip)', () async {
    final c = make(intro: 'intro.mp4');
    await c.initialize();
    await c.play();

    // Native chains intro (once) -> loop (forever); no separate loop call, no
    // dependence on an 'ended' event to start the loop.
    expect(c.state, NeoVapState.playingLoop);
    expect(
      backend.calls,
      containsAllInOrder(['allocate', 'play:intro.mp4:repeat=1:next=loop.mp4']),
    );
  });

  test('re-entry skips the intro and plays the loop directly', () async {
    final c = make(intro: 'intro.mp4');
    await c.initialize();
    await c.play(); // intro -> loop (intro consumed)

    backend.calls.clear();
    await c.play(); // second call == re-entry

    expect(backend.calls, ['play:loop.mp4:repeat=-1']);
    expect(backend.calls.every((c) => !c.startsWith('play:intro')), isTrue);
  });

  test('with no intro, plays the loop directly', () async {
    final c = make();
    await c.initialize();
    await c.play();
    expect(c.state, NeoVapState.playingLoop);
    expect(backend.calls.last, 'play:loop.mp4:repeat=-1');
  });

  test('placeholder hides on first frame and re-shows on error', () async {
    String? captured;
    final c = make(onError: (m) => captured = m);
    await c.initialize();
    expect(c.showPlaceholder, isTrue);

    backend.emit(const NeoVapEvent(42, NeoVapEventType.firstFrame));
    await pumpEventQueue();
    expect(c.showPlaceholder, isFalse);

    backend.emit(const NeoVapEvent(42, NeoVapEventType.error, message: 'boom'));
    await pumpEventQueue();
    expect(c.showPlaceholder, isTrue);
    expect(c.state, NeoVapState.error);
    expect(captured, 'boom');
  });

  test('ended keeps the placeholder hidden (freezes on the last frame)',
      () async {
    // A finite clip ending is neither an error nor a reset, so the last
    // rendered frame stays on screen — the placeholder must NOT re-show (that
    // is reserved for stop() and error).
    final c = make();
    await c.initialize();
    await c.play(); // playingLoop
    backend.emit(const NeoVapEvent(42, NeoVapEventType.firstFrame));
    await pumpEventQueue();
    expect(c.showPlaceholder, isFalse);

    backend.emit(const NeoVapEvent(42, NeoVapEventType.ended));
    await pumpEventQueue();
    expect(c.state, NeoVapState.ended);
    expect(c.showPlaceholder, isFalse); // frozen on last frame, not reset
  });

  test('placeholder never hides without a firstFrame event (no timer)',
      () async {
    // The placeholder is event-driven: only a real firstFrame hides it. Time
    // passing alone must not — guards against a regression to a timed reveal.
    final c = make();
    await c.initialize();
    await c.play();
    expect(c.showPlaceholder, isTrue);
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(c.showPlaceholder, isTrue);
  });

  test('info event exposes the content aspect', () async {
    final c = make();
    await c.initialize();
    expect(c.contentAspect, isNull);

    backend.emit(const NeoVapEvent(42, NeoVapEventType.info,
        width: 1504, height: 846));
    await pumpEventQueue();
    expect(c.contentAspect, closeTo(1504 / 846, 1e-9));
  });

  test('info with a non-positive dimension is ignored', () async {
    final c = make();
    await c.initialize();
    // "0x846"/negatives pass int.tryParse but must not set a 0/negative aspect
    // that would collapse the view — the caller-supplied aspect stays in force.
    backend.emit(
        const NeoVapEvent(42, NeoVapEventType.info, width: 0, height: 846));
    backend.emit(
        const NeoVapEvent(42, NeoVapEventType.info, width: -5, height: 846));
    await pumpEventQueue();
    expect(c.contentAspect, isNull);
  });

  test('ignores events for other textures', () async {
    final c = make();
    await c.initialize();
    backend.emit(const NeoVapEvent(999, NeoVapEventType.firstFrame));
    await pumpEventQueue();
    expect(c.showPlaceholder, isTrue); // unchanged
  });

  test('dispose releases the texture and marks disposed', () async {
    final c = make();
    await c.initialize();
    c.dispose();
    expect(c.state, NeoVapState.disposed);
    expect(backend.calls, contains('dispose'));
  });

  test('dispose never routes through stop() (NEO-1731 regression guard)',
      () async {
    // The flutter_vap_plus bug was a per-view stop() inside dispose(), which
    // raised MissingPluginException during teardown. neo_vap must release the
    // texture directly; this fails if stop()-in-dispose is ever reintroduced.
    final c = make(intro: 'intro.mp4');
    await c.initialize();
    await c.play();
    backend.calls.clear();
    c.dispose();
    expect(backend.calls, contains('dispose'));
    expect(backend.calls, isNot(contains('stop')));
  });

  test('dispose while initialize is in flight does not throw', () async {
    final c = make();
    final pending = c.initialize(); // allocateTexture awaiting
    c.dispose(); // disposed before it resolves
    await pending; // must not throw "used after being disposed"
    expect(c.state, NeoVapState.disposed);
  });

  test('initialize failure resets to idle so a remount can retry', () async {
    // Texture allocation failing leaves no texture to latch onto, so _fail
    // resets to idle rather than latching NeoVapState.error — a permanent
    // error state would leave a remount unable to retry (commit 7e8af39).
    // Playback failures, which do have a texture, still latch as error.
    backend.failAllocate = true;
    String? err;
    final c = make(onError: (m) => err = m);
    await c.initialize();
    expect(c.state, NeoVapState.idle);
    expect(err, isNotNull);
  });

  test('onEnd fires when a finite loop ends', () async {
    var ended = false;
    final c = make(onEnd: () => ended = true);
    await c.initialize();
    await c.play(); // playingLoop
    backend.emit(const NeoVapEvent(42, NeoVapEventType.ended));
    await pumpEventQueue();
    expect(ended, isTrue);
    expect(c.state, NeoVapState.ended);
  });

  test('controllers share one default backend (single native subscription)', () {
    // Guards the fix for the shared-eventSink race: if this regresses to a
    // per-controller MethodChannelNeoVap, each opens its own EventChannel and a
    // disposing controller's cancel nulls the shared native sink.
    final a = NeoVapController(videoAsset: 'a.mp4');
    final b = NeoVapController(videoAsset: 'b.mp4');
    expect(identical(a.backend, b.backend), isTrue);
    a.dispose();
    b.dispose();
  });

  test('shared backend demuxes events by textureId; dispose one keeps other',
      () async {
    backend.allocatedId = 1;
    final a = NeoVapController(videoAsset: 'a.mp4', backend: backend);
    await a.initialize();
    backend.allocatedId = 2;
    final b = NeoVapController(videoAsset: 'b.mp4', backend: backend);
    await b.initialize();

    a.dispose(); // must not starve b
    backend.emit(const NeoVapEvent(2, NeoVapEventType.firstFrame));
    await pumpEventQueue();
    expect(b.showPlaceholder, isFalse);
  });

  test('stop() ignores a later stale ended event', () async {
    var ended = false;
    final c = make(onEnd: () => ended = true);
    await c.initialize();
    await c.play();
    await c.stop();
    expect(c.state, NeoVapState.ready);

    backend.emit(const NeoVapEvent(42, NeoVapEventType.ended));
    await pumpEventQueue();
    expect(ended, isFalse); // must not resurrect playback or misfire onEnd
    expect(c.state, NeoVapState.ready);
  });

  group('rejecting backend (MissingPluginException)', () {
    // Both teardown calls run unawaited at their real call sites — a page swipe
    // stops the off-screen controller, and dispose() fires and forgets — so an
    // escaping rejection has no caller left to catch it and lands as an
    // unhandled async error. In a test zone that fails the test, which is the
    // assertion: these pass only while the guards are in place.
    late RejectingBackend rejecting;

    setUp(() => rejecting = RejectingBackend());
    tearDown(() => rejecting.close());

    test('stop() reports the failure and still applies its local intent',
        () async {
      final errors = <String>[];
      final c = NeoVapController(
        videoAsset: 'loop.mp4',
        backend: rejecting,
        onError: errors.add,
      );
      await c.initialize();
      await c.play();

      await c.stop(); // must not throw

      expect(errors.single, contains('stop failed'));
      expect(c.showPlaceholder, isTrue);
      // A failed stop is not a render failure — the controller stays usable.
      expect(c.state, NeoVapState.ready);
      c.dispose();
      await pumpEventQueue();
    });

    test('dispose() swallows the rejection', () async {
      final c = NeoVapController(videoAsset: 'loop.mp4', backend: rejecting);
      await c.initialize();

      c.dispose();
      await pumpEventQueue();

      expect(rejecting.calls, contains('dispose'));
    });
  });
}
