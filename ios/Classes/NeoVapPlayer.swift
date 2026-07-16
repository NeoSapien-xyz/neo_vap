import AVFoundation
import CoreVideo
import Flutter
import Metal
import QuartzCore
import simd

/// One texture's playback: AVPlayer decode (VideoToolbox) -> Metal alpha-
/// composite -> Flutter texture. The iOS mirror of `NeoVapPlayer.kt`.
///
/// A decoded BGRA `CVPixelBuffer` is pulled each display-link tick, composited
/// by the shared [MetalCompositor] into a pool-recycled BGRA output buffer, and
/// handed to Flutter via the [FlutterTexture] `copyPixelBuffer` protocol. The
/// pipeline is built lazily on the first `play` (which supplies the asset whose
/// `vapc` geometry sizes everything), exactly like the Android renderer.
///
/// All methods are called on the main thread (method channel + main-runloop
/// display link).
final class NeoVapPlayer: NSObject, FlutterTexture {
  static let loopForever = -1

  /// Set by the plugin right after `register`; needed to signal frame arrival.
  var textureId: Int64 = 0

  private let registry: FlutterTextureRegistry

  /// Set by the plugin (capturing the texture id by value) after `register`, so
  /// the emit closure never retains this player — avoids a player↔closure cycle.
  var onEvent: (_ event: String, _ message: String?) -> Void = { _, _ in }

  private var info: VapcInfo?
  private var player: AVQueuePlayer?
  private var videoOutput: AVPlayerItemVideoOutput?
  private var displayLink: CADisplayLink?
  private var currentItemObservation: NSKeyValueObservation?
  private var outputAttachedItem: AVPlayerItem?

  private var textureCache: CVMetalTextureCache?
  private var pixelBufferPool: CVPixelBufferPool?

  // Read on the Flutter raster thread (copyPixelBuffer), written on main
  // (display link) — guard the handoff.
  private var latestPixelBuffer: CVPixelBuffer?
  private let bufferLock = NSLock()

  private var firstFrameSent = false
  private var released = false

  // U5: host time when play() was last called, to measure play→first-frame
  // latency on device (cold vs prewarmed). Logged once, on the first frame.
  private var playStartTime: CFTimeInterval = 0

  // Intro/loop bookkeeping (see `onItemEnd`).
  private var loopURL: URL?
  private weak var introItem: AVPlayerItem?
  private var ownedItems = Set<ObjectIdentifier>()

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
    super.init()
  }

  /// Play [assetURL]. With [nextURL], play [assetURL] once then loop [nextURL]
  /// forever (the intro→loop case). Otherwise [repeatMode] == -1 loops
  /// [assetURL] forever, else plays it once (emitting `ended` at the end).
  ///
  /// [vapcSource] is the asset (usually the intro) whose `vapc` sizes the output
  /// texture — mirrors Android sizing off the first asset.
  func play(assetURL: URL, vapcSource: URL, repeatMode: Int, nextURL: URL?) {
    playStartTime = CACurrentMediaTime()
    do {
      try ensureConfigured(vapcSource: vapcSource)
    } catch {
      onEvent("error", "neo_vap init failed: \(error)")
      return
    }
    guard let player = player else { return }

    // Reset queue + bookkeeping for a fresh play.
    player.removeAllItems()
    ownedItems.removeAll()
    introItem = nil
    loopURL = nil

    if let nextURL = nextURL {
      // intro once, then loop nextURL forever. The queue prebuffers the loop
      // while the intro plays → gapless transition (KTD-6 preroll). Two loop
      // items are queued so loop→loop is also gapless; `onItemEnd` tops it up.
      loopURL = nextURL
      let intro = makeItem(assetURL)
      introItem = intro
      player.insert(intro, after: nil)
      player.insert(makeItem(nextURL), after: intro)
      player.insert(makeItem(nextURL), after: player.items().last)
    } else if repeatMode == Self.loopForever {
      loopURL = assetURL
      let first = makeItem(assetURL)
      player.insert(first, after: nil)
      player.insert(makeItem(assetURL), after: first)
    } else {
      // Finite standalone play: one item; `onItemEnd` emits `ended`.
      player.insert(makeItem(assetURL), after: nil)
    }
    player.play()
  }

  /// Create a queue item and record it as ours, so `onItemEnd` can tell this
  /// player's ends from other NeoVapPlayers' (all share the NotificationCenter).
  private func makeItem(_ url: URL) -> AVPlayerItem {
    let item = AVPlayerItem(url: url)
    ownedItems.insert(ObjectIdentifier(item))
    return item
  }

  func stop() {
    player?.pause()
    player?.seek(to: .zero)
  }

  func dispose() {
    released = true
    displayLink?.invalidate()
    displayLink = nil
    currentItemObservation?.invalidate()
    currentItemObservation = nil
    NotificationCenter.default.removeObserver(self)
    player?.pause()
    player?.removeAllItems()
    player = nil
    ownedItems.removeAll()
    outputAttachedItem = nil
    videoOutput = nil
    bufferLock.lock()
    latestPixelBuffer = nil
    bufferLock.unlock()
    if let cache = textureCache { CVMetalTextureCacheFlush(cache, 0) }
    textureCache = nil
    pixelBufferPool = nil
  }

  // MARK: - FlutterTexture

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    bufferLock.lock()
    defer { bufferLock.unlock() }
    guard let pb = latestPixelBuffer else { return nil }
    return Unmanaged.passRetained(pb)
  }

  // MARK: - one-time setup

  private func ensureConfigured(vapcSource: URL) throws {
    // ponytail: sized once from the first asset's vapc — safe since intro/loop
    // share geometry. A later asset with different geometry on the same texture
    // would mis-crop; recreate the pipeline per-play if that ever happens.
    if player != nil { return }
    guard let comp = MetalCompositor.shared else {
      throw VapcParseError("Metal unavailable")
    }

    let info = try VapcInfo.parse(Data(contentsOf: vapcSource))
    self.info = info
    // Report the real content size so Dart can size the view off the clip's
    // aspect instead of a hardcoded value. Emitted once, before any frame.
    onEvent("info", "\(info.width)x\(info.height)")

    var cache: CVMetalTextureCache?
    guard
      CVMetalTextureCacheCreate(nil, nil, comp.device, nil, &cache) == kCVReturnSuccess,
      let cache = cache
    else { throw VapcParseError("CVMetalTextureCache create failed") }
    textureCache = cache

    let poolAttrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: info.width,
      kCVPixelBufferHeightKey as String: info.height,
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    var pool: CVPixelBufferPool?
    guard
      CVPixelBufferPoolCreate(nil, nil, poolAttrs as CFDictionary, &pool) == kCVReturnSuccess,
      let pool = pool
    else { throw VapcParseError("CVPixelBufferPool create failed") }
    pixelBufferPool = pool

    videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])

    let player = AVQueuePlayer()
    player.actionAtItemEnd = .advance
    player.isMuted = true // background animation — never emit audio
    self.player = player

    // Keep the single video output attached to whichever item is current — this
    // follows the queue's gapless advances (intro→loop and loop→loop).
    currentItemObservation = player.observe(\.currentItem, options: [.new]) {
      [weak self] _, change in
      if let item = change.newValue ?? nil { self?.attachOutput(to: item) }
    }

    NotificationCenter.default.addObserver(
      self, selector: #selector(onItemEnd(_:)),
      name: .AVPlayerItemDidPlayToEndTime, object: nil
    )

    let link = CADisplayLink(target: self, selector: #selector(onDisplayLink(_:)))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  private func attachOutput(to item: AVPlayerItem) {
    guard let output = videoOutput, outputAttachedItem !== item else { return }
    // An AVPlayerItemVideoOutput can be attached to only one item at a time.
    outputAttachedItem?.remove(output)
    item.add(output)
    outputAttachedItem = item
  }

  @objc private func onItemEnd(_ note: Notification) {
    guard
      let ended = note.object as? AVPlayerItem,
      // Only our items (the notification is global; other players share it). The
      // ended item is already removed from `items()` on `.advance`, so identity
      // tracking — not queue membership — is what tells it apart.
      ownedItems.remove(ObjectIdentifier(ended)) != nil,
      let player = player
    else { return }
    if ended === introItem { return } // gapless advance to the queued loop
    if let loopURL = loopURL {
      // Top the loop up so there's always one item prebuffered ahead.
      player.insert(makeItem(loopURL), after: player.items().last)
    } else {
      onEvent("ended", nil)
    }
  }

  // MARK: - frame pump (main runloop)

  @objc private func onDisplayLink(_ link: CADisplayLink) {
    guard !released, let output = videoOutput else { return }
    let hostTime = link.timestamp + link.duration
    let itemTime = output.itemTime(forHostTime: hostTime)
    guard output.hasNewPixelBuffer(forItemTime: itemTime) else { return }
    guard
      let src = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil),
      let out = composite(src)
    else { return }

    bufferLock.lock()
    latestPixelBuffer = out
    bufferLock.unlock()
    registry.textureFrameAvailable(textureId)

    if !firstFrameSent {
      firstFrameSent = true
      // U5: play→first-frame latency (includes cold pipeline + decoder start on
      // the first play; prewarm should shrink the pipeline part). Read off the
      // device console to compare cold vs prewarmed.
      let ms = (CACurrentMediaTime() - playStartTime) * 1000
      NSLog(String(format: "neo_vap: first-frame latency %.1f ms", ms))
      onEvent("firstFrame", nil)
    }
  }

  private func composite(_ src: CVPixelBuffer) -> CVPixelBuffer? {
    guard
      let comp = MetalCompositor.shared,
      let cache = textureCache,
      let pool = pixelBufferPool,
      let info = info,
      let (inTex, inCV) = makeTexture(src, cache: cache),
      let outPB = makePoolBuffer(pool),
      let (outTex, outCV) = makeTexture(outPB, cache: cache),
      let cmd = comp.queue.makeCommandBuffer()
    else { return nil }

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = outTex
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0) // transparent
    pass.colorAttachments[0].storeAction = .store
    guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }

    enc.setRenderPipelineState(comp.pipeline)
    enc.setFragmentTexture(inTex, index: 0)
    var rects = NeoVapRects(
      videoSize: simd_float4(Float(info.videoWidth), Float(info.videoHeight), 0, 0),
      rgbRect: rect(info.rgbFrame),
      aRect: rect(info.aFrame)
    )
    enc.setFragmentBytes(&rects, length: MemoryLayout<NeoVapRects>.stride, index: 0)
    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    enc.endEncoding()
    // Hold the CVMetalTextures (and thus the mapped CVPixelBuffers) until the
    // GPU finishes reading/writing them.
    cmd.addCompletedHandler { _ in _ = inCV; _ = outCV }
    cmd.commit()
    CVMetalTextureCacheFlush(cache, 0)
    return outPB
  }

  private func rect(_ r: VapcRect) -> simd_float4 {
    simd_float4(Float(r.x), Float(r.y), Float(r.w), Float(r.h))
  }

  private func makeTexture(
    _ pb: CVPixelBuffer, cache: CVMetalTextureCache
  ) -> (MTLTexture, CVMetalTexture)? {
    let w = CVPixelBufferGetWidth(pb)
    let h = CVPixelBufferGetHeight(pb)
    var cv: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cv)
    guard status == kCVReturnSuccess, let cv = cv, let tex = CVMetalTextureGetTexture(cv) else {
      return nil
    }
    return (tex, cv)
  }

  private func makePoolBuffer(_ pool: CVPixelBufferPool) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess else {
      return nil
    }
    return pb
  }
}
