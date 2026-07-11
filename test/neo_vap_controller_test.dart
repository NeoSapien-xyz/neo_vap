import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_vap/neo_vap.dart';

/// Records backend calls and lets tests inject native events.
class FakeBackend implements NeoVapBackend {
  final List<String> calls = [];
  final StreamController<NeoVapEvent> _events =
      StreamController<NeoVapEvent>.broadcast();
  int allocatedId = 42;

  @override
  Future<int> allocateTexture() async {
    calls.add('allocate');
    return allocatedId;
  }

  @override
  Future<void> prewarm({String? warmupAsset}) async => calls.add('prewarm');

  @override
  Future<void> prepare(int textureId, String asset) async =>
      calls.add('prepare:$asset');

  @override
  Future<void> play(
    int textureId,
    String asset, {
    int repeat = kNeoVapLoopForever,
    bool keepLastFrame = true,
  }) async =>
      calls.add('play:$asset:repeat=$repeat');

  @override
  Future<void> stop(int textureId) async => calls.add('stop');

  @override
  Future<void> dispose(int textureId) async => calls.add('dispose');

  @override
  Stream<NeoVapEvent> get events => _events.stream;

  void emit(NeoVapEvent e) => _events.add(e);
  Future<void> close() => _events.close();
}

void main() {
  late FakeBackend backend;

  setUp(() => backend = FakeBackend());
  tearDown(() => backend.close());

  NeoVapController make({String? intro, void Function(String)? onError}) =>
      NeoVapController(
        videoAsset: 'loop.mp4',
        introAsset: intro,
        backend: backend,
        onError: onError,
      );

  test('initialize allocates a texture and becomes ready', () async {
    final c = make();
    await c.initialize();
    expect(c.textureId, 42);
    expect(c.state, NeoVapState.ready);
    expect(backend.calls, contains('allocate'));
  });

  test('intro plays once, then chains to the infinite loop', () async {
    final c = make(intro: 'intro.mp4');
    await c.initialize();
    await c.play();

    expect(c.state, NeoVapState.playingIntro);
    expect(
      backend.calls,
      containsAllInOrder([
        'allocate',
        'prepare:loop.mp4', // loop prerolled while intro plays (KTD-6)
        'play:intro.mp4:repeat=1',
      ]),
    );

    backend.emit(const NeoVapEvent(42, NeoVapEventType.ended));
    await pumpEventQueue();

    expect(c.state, NeoVapState.playingLoop);
    expect(backend.calls.last, 'play:loop.mp4:repeat=-1');
  });

  test('re-entry skips the intro and plays the loop directly', () async {
    final c = make(intro: 'intro.mp4');
    await c.initialize();
    await c.play();
    backend.emit(const NeoVapEvent(42, NeoVapEventType.ended));
    await pumpEventQueue();

    backend.calls.clear();
    await c.play(); // second call == re-entry

    expect(backend.calls, ['play:loop.mp4:repeat=-1']);
    expect(backend.calls, isNot(contains('play:intro.mp4:repeat=1')));
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
}
