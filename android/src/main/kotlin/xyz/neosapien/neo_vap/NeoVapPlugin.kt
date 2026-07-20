package xyz.neosapien.neo_vap

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry

/**
 * Texture-based transparent VAP player. Owns the method/event channels and a
 * map of live [NeoVapPlayer]s keyed by texture id. Decode + composite happen
 * per-player (ExoPlayer -> GL -> SurfaceProducer); this class is just wiring.
 */
class NeoVapPlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var context: Context
    private lateinit var textureRegistry: TextureRegistry

    private val players = mutableMapOf<Long, NeoVapPlayer>()
    private val main = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        textureRegistry = binding.textureRegistry
        methodChannel = MethodChannel(binding.binaryMessenger, "neo_vap")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "neo_vap/events")
        eventChannel.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        try {
            when (call.method) {
                "allocateTexture" -> {
                    val producer = textureRegistry.createSurfaceProducer()
                    val id = producer.id()
                    players[id] = NeoVapPlayer(context, producer) { event, message ->
                        emit(id, event, message)
                    }
                    result.success(id)
                }
                "play" -> {
                    player(call)?.play(
                        call.arg("asset"),
                        call.argument<Int>("repeat") ?: NeoVapPlayer.LOOP_FOREVER,
                        call.argument<String>("nextAsset"),
                    )
                    result.success(null)
                }
                "stop" -> {
                    player(call)?.stop()
                    result.success(null)
                }
                "dispose" -> {
                    players.remove(textureId(call))?.dispose()
                    result.success(null)
                }
                "prewarm" -> {
                    prewarm()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("neo_vap", e.message, null)
        }
    }

    /**
     * Warm the GL driver + shader compiler once per process so the first real
     * `play` doesn't pay the cold EGL-init + program-compile stall. Runs off the
     * main thread; best-effort, so any failure just means the first play pays
     * full cold-start.
     *
     * Measured on a vivo V2521 (API 35, Adreno, c2.qti.avc.decoder), profile
     * build, cold start: native init (asset read + vapc parse + GL + ExoPlayer
     * construction) is 38-71ms total, of which GL is ~3-27ms. The first real
     * decoded frame lands at t+313-334ms — i.e. init is only ~15% of
     * time-to-content. The other ~260ms is downstream of `prepare()`: MediaSource
     * load and extractor parse (~156ms) then codec init and first decode (~61ms).
     * Optimising init further has little left to win; that ~260ms is the target.
     *
     * Deliberately NOT warmed here: `MediaCodecUtil.warmDecoderInfoCache`.
     * `getDecoderInfos` is `static synchronized`, so warming it on this thread
     * does not delete the cost for a play starting moments later — the play just
     * blocks on the same monitor. It also enumerates the whole MediaCodecList,
     * which is itself the source of the ~30 AudioCapabilities/VideoCapabilities
     * "Unsupported mime" warnings (verified on tid neo_vap_prewarm) — so it adds
     * the log spam it was assumed to avoid. Revisit only with real runway ahead
     * of the first play.
     */
    private fun prewarm() {
        if (warmed) return
        warmed = true
        Thread {
            // 16x16 throwaway geometry: enough to run initGl (EGL init + OES
            // texture + shader compile/link), which is all we're warming.
            val dummy = VapcInfo(
                version = 2, frameCount = 1, width = 16, height = 16, fps = 25,
                videoWidth = 16, videoHeight = 16,
                rgbFrame = VapcRect(0, 0, 16, 16), aFrame = VapcRect(0, 0, 16, 16),
                isVapx = false, orientation = 0,
            )
            val start = SystemClock.elapsedRealtime()
            // Construct inside the try: NeoVapRenderer() starts a HandlerThread, so
            // a thread-creation/OOM failure must hit the best-effort catch too —
            // an uncaught throw on this worker thread would kill the process.
            var r: NeoVapRenderer? = null
            try {
                r = NeoVapRenderer(dummy) {}
                r.awaitInputSurface()
                Log.i("neo_vap", "prewarm: GL pipeline warmed in ${SystemClock.elapsedRealtime() - start}ms")
            } catch (t: Throwable) {
                // swallow — warm is best-effort; log so a silent failure is visible
                Log.w("neo_vap", "prewarm skipped (GL warm failed): ${t.message}")
            } finally {
                r?.release()
            }
        }.apply { name = "neo_vap_prewarm" }.start()
    }

    private fun player(call: MethodCall): NeoVapPlayer? = players[textureId(call)]

    private fun textureId(call: MethodCall): Long =
        call.argument<Number>("textureId")!!.toLong()

    private fun MethodCall.arg(key: String): String = argument<String>(key)!!

    private fun emit(id: Long, event: String, message: String?) = main.post {
        eventSink?.success(mapOf("textureId" to id, "event" to event, "message" to message))
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        players.values.forEach { it.dispose() }
        players.clear()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        eventSink = null
    }

    companion object {
        // Process-wide: prewarm the GL pipeline at most once, even across engine
        // re-attach. Best-effort, so it's never reset on failure (no retry storm).
        @Volatile
        private var warmed = false
    }
}
