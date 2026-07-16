import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neo_vap/src/neo_vap_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('decodeEvent', () {
    test('maps firstFrame / ended / error', () {
      expect(
        MethodChannelNeoVap.decodeEvent(
                {'textureId': 1, 'event': 'firstFrame'})
            .type,
        NeoVapEventType.firstFrame,
      );
      expect(
        MethodChannelNeoVap.decodeEvent({'textureId': 1, 'event': 'ended'}).type,
        NeoVapEventType.ended,
      );
      final err = MethodChannelNeoVap.decodeEvent(
          {'textureId': 2, 'event': 'error', 'message': 'boom'});
      expect(err.type, NeoVapEventType.error);
      expect(err.textureId, 2);
      expect(err.message, 'boom');
    });

    test('unknown event decodes as an error carrying the raw name', () {
      final e = MethodChannelNeoVap.decodeEvent({'textureId': 1, 'event': 'wat'});
      expect(e.type, NeoVapEventType.error);
      expect(e.message, contains('wat'));
    });

    test('info decodes the "WxH" content size', () {
      final e = MethodChannelNeoVap.decodeEvent(
          {'textureId': 3, 'event': 'info', 'message': '1504x846'});
      expect(e.type, NeoVapEventType.info);
      expect(e.width, 1504);
      expect(e.height, 846);
    });

    test('malformed info size decodes to null dimensions', () {
      final e = MethodChannelNeoVap.decodeEvent(
          {'textureId': 3, 'event': 'info', 'message': 'garbage'});
      expect(e.type, NeoVapEventType.info);
      expect(e.width, isNull);
      expect(e.height, isNull);
    });
  });

  group('method invocations', () {
    const channel = MethodChannel('neo_vap');
    late List<MethodCall> calls;
    late MethodChannelNeoVap backend;

    void mock(Future<Object?>? Function(MethodCall)? handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
    }

    setUp(() {
      calls = [];
      backend = MethodChannelNeoVap();
      mock((call) async {
        calls.add(call);
        return call.method == 'allocateTexture' ? 7 : null;
      });
    });

    tearDown(() => mock(null));

    test('allocateTexture returns the platform id', () async {
      expect(await backend.allocateTexture(), 7);
    });

    test('allocateTexture throws when the platform returns null', () async {
      mock((call) async => null);
      expect(backend.allocateTexture(), throwsStateError);
    });

    test('play forwards the loop sentinel and args', () async {
      await backend.play(3, 'loop.mp4', repeat: kNeoVapLoopForever);
      final call = calls.single;
      expect(call.method, 'play');
      expect(call.arguments['textureId'], 3);
      expect(call.arguments['asset'], 'loop.mp4');
      expect(call.arguments['repeat'], -1);
    });

    test('stop / dispose / prewarm each invoke their method', () async {
      await backend.stop(1);
      await backend.dispose(1);
      await backend.prewarm(warmupAsset: 'w.mp4');
      expect(
        calls.map((c) => c.method),
        ['stop', 'dispose', 'prewarm'],
      );
    });
  });
}
