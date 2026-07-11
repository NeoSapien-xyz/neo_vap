import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

/// Single loop sentinel (KTD-7): `repeat: kNeoVapLoopForever` plays the clip
/// indefinitely (native seeks-to-0 on end). Any positive value plays that many
/// times. There is deliberately only one "infinite" constant on the Dart side.
const int kNeoVapLoopForever = -1;

/// Play the clip exactly once (used for the intro before chaining to the loop).
const int kNeoVapPlayOnce = 1;

/// Kinds of native → Dart playback events.
enum NeoVapEventType { firstFrame, ended, error }

/// A playback event for a specific texture, delivered from the native backend.
class NeoVapEvent {
  const NeoVapEvent(this.textureId, this.type, {this.message});

  final int textureId;
  final NeoVapEventType type;

  /// Error detail; only set when [type] is [NeoVapEventType.error].
  final String? message;

  @override
  String toString() =>
      'NeoVapEvent(tex $textureId, $type${message != null ? ', "$message"' : ''})';
}

/// The native operations `NeoVapController` needs.
///
/// A plain abstract seam (not `plugin_platform_interface` — this is a single,
/// non-federated package per KTD-8). Two implementations exist: the real
/// [MethodChannelNeoVap] and the fake used by controller tests, which is the
/// only reason this abstraction exists.
abstract class NeoVapBackend {
  /// Register a texture with the engine and return its id.
  Future<int> allocateTexture();

  /// Warm the decoder + shader pipeline at app init so the first play skips the
  /// cold-start compile/allocate stall. [warmupAsset], if given, decodes one
  /// frame to force pipeline-state compilation.
  Future<void> prewarm({String? warmupAsset});

  /// Play [asset] on [textureId]. [repeat] uses [kNeoVapLoopForever] /
  /// [kNeoVapPlayOnce] (or any positive count).
  ///
  /// With [nextAsset], [asset] plays once then [nextAsset] loops forever —
  /// chained gaplessly by the native player (no event round-trip), which keeps
  /// the intro→loop sequence seamless and race-proof.
  Future<void> play(
    int textureId,
    String asset, {
    int repeat = kNeoVapLoopForever,
    String? nextAsset,
  });

  /// Stop playback on [textureId] (texture stays allocated).
  Future<void> stop(int textureId);

  /// Release [textureId]'s player, decoder, and texture registration.
  Future<void> dispose(int textureId);

  /// Broadcast stream of events for all textures; consumers filter by id.
  Stream<NeoVapEvent> get events;
}

/// Real backend backed by platform method/event channels.
class MethodChannelNeoVap implements NeoVapBackend {
  MethodChannelNeoVap({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _method = methodChannel ?? const MethodChannel('neo_vap'),
        _eventChannel = eventChannel ?? const EventChannel('neo_vap/events');

  final MethodChannel _method;
  final EventChannel _eventChannel;
  Stream<NeoVapEvent>? _events;

  @override
  Future<int> allocateTexture() async {
    final id = await _method.invokeMethod<int>('allocateTexture');
    if (id == null) {
      throw StateError('neo_vap: allocateTexture returned null');
    }
    return id;
  }

  @override
  Future<void> prewarm({String? warmupAsset}) =>
      _method.invokeMethod<void>('prewarm', {'warmupAsset': warmupAsset});

  @override
  Future<void> play(
    int textureId,
    String asset, {
    int repeat = kNeoVapLoopForever,
    String? nextAsset,
  }) =>
      _method.invokeMethod<void>('play', {
        'textureId': textureId,
        'asset': asset,
        'repeat': repeat,
        'nextAsset': nextAsset,
      });

  @override
  Future<void> stop(int textureId) =>
      _method.invokeMethod<void>('stop', {'textureId': textureId});

  @override
  Future<void> dispose(int textureId) =>
      _method.invokeMethod<void>('dispose', {'textureId': textureId});

  @override
  Stream<NeoVapEvent> get events =>
      _events ??= _eventChannel.receiveBroadcastStream().map(decodeEvent);

  /// Maps a raw platform event map to a [NeoVapEvent]. Public only for tests.
  @visibleForTesting
  static NeoVapEvent decodeEvent(dynamic raw) {
    final map = (raw as Map).cast<String, dynamic>();
    final textureId = (map['textureId'] as num).toInt();
    switch (map['event'] as String?) {
      case 'firstFrame':
        return NeoVapEvent(textureId, NeoVapEventType.firstFrame);
      case 'ended':
        return NeoVapEvent(textureId, NeoVapEventType.ended);
      case 'error':
        return NeoVapEvent(
          textureId,
          NeoVapEventType.error,
          message: map['message'] as String?,
        );
      default:
        return NeoVapEvent(
          textureId,
          NeoVapEventType.error,
          message: 'unknown event: ${map['event']}',
        );
    }
  }
}
