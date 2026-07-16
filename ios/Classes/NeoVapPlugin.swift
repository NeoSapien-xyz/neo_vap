import Flutter
import UIKit

/// Texture-based transparent VAP player. Owns the method/event channels and a
/// map of live [NeoVapPlayer]s keyed by texture id (the iOS mirror of
/// `NeoVapPlugin.kt`). Decode + composite happen per-player (AVPlayer -> Metal
/// -> FlutterTexture); this class is just wiring.
public class NeoVapPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let registrar: FlutterPluginRegistrar
  private let textures: FlutterTextureRegistry
  private var players = [Int64: NeoVapPlayer]()
  private var eventSink: FlutterEventSink?

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    self.textures = registrar.textures()
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = NeoVapPlugin(registrar: registrar)
    let channel = FlutterMethodChannel(name: "neo_vap", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    let events = FlutterEventChannel(name: "neo_vap/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "allocateTexture":
      let player = NeoVapPlayer(registry: textures)
      let id = textures.register(player)
      player.textureId = id
      player.onEvent = { [weak self] event, message in
        self?.emit(textureId: id, event: event, message: message)
      }
      players[id] = player
      result(id)

    case "play":
      guard
        let args = args, let id = int64(args["textureId"]),
        let asset = args["asset"] as? String, let url = assetURL(asset)
      else { return result(argError("play")) }
      let next = (args["nextAsset"] as? String).flatMap(assetURL)
      players[id]?.play(
        assetURL: url,
        vapcSource: url,
        repeatMode: (args["repeat"] as? Int) ?? NeoVapPlayer.loopForever,
        nextURL: next
      )
      result(nil)

    case "stop":
      players[textureId(args)]?.stop()
      result(nil)

    case "dispose":
      let id = textureId(args)
      players.removeValue(forKey: id)?.dispose()
      textures.unregisterTexture(id)
      result(nil)

    case "prewarm":
      prewarm()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Warm the Metal device + composite pipeline once per process so the first
  /// real play doesn't pay the cold PSO/shader-compile stall (the iOS latency
  /// fix). Runs off the main thread; best-effort, so any failure just means the
  /// first play pays full cold-start.
  ///
  /// The three prewarm-hardening lessons carried from Android:
  ///  1. All construction is inside `MetalCompositor.init?` (returns nil, never
  ///     throws) so a build failure on this background thread can't crash init.
  ///  2. The Dart facade is fire-and-forget (`.catchError`), so having a real
  ///     handler here just means it succeeds instead of MissingPlugin-rejecting.
  ///  3. No blocking latch on the main thread — this dispatches async and returns
  ///     immediately; nothing the main thread waits on can wedge it (no ANR).
  private func prewarm() {
    DispatchQueue.global(qos: .utility).async {
      if MetalCompositor.shared != nil {
        NSLog("neo_vap: prewarm — Metal composite pipeline warmed")
      } else {
        NSLog("neo_vap: prewarm skipped (Metal unavailable)")
      }
    }
  }

  // MARK: - helpers

  private func assetURL(_ asset: String) -> URL? {
    let key = registrar.lookupKey(forAsset: asset)
    guard let path = Bundle.main.path(forResource: key, ofType: nil) else { return nil }
    return URL(fileURLWithPath: path)
  }

  private func int64(_ any: Any?) -> Int64? { (any as? NSNumber)?.int64Value }

  private func textureId(_ args: [String: Any]?) -> Int64 {
    int64(args?["textureId"]) ?? -1
  }

  private func argError(_ method: String) -> FlutterError {
    FlutterError(code: "neo_vap", message: "bad arguments for \(method)", details: nil)
  }

  private func emit(textureId: Int64, event: String, message: String?) {
    // NSNull (not a Swift nil-in-dict, which bridges to the codec badly) so Dart
    // reads `message` back as null. Matches the Android event map shape.
    let payload: [String: Any] = [
      "textureId": textureId, "event": event, "message": message ?? NSNull(),
    ]
    DispatchQueue.main.async { [weak self] in self?.eventSink?(payload) }
  }

  // MARK: - FlutterStreamHandler

  public func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments _: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  public func detachFromEngine(for _: FlutterPluginRegistrar) {
    players.values.forEach { $0.dispose() }
    players.removeAll()
    eventSink = nil
  }
}
