package xyz.neosapien.neo_vap

import android.content.Context
import android.os.Handler
import android.os.Looper
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
                    player(call)?.play(call.arg("asset"), call.argument<Int>("repeat") ?: -1)
                    result.success(null)
                }
                "prepare" -> {
                    player(call)?.prepare(call.arg("asset"))
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
                // U5 owns real cold-start prewarm; a no-op keeps the contract complete.
                "prewarm" -> result.success(null)
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("neo_vap", e.message, null)
        }
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
}
