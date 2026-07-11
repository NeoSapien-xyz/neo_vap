package xyz.neosapien.neo_vap

import android.content.Context
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import io.flutter.FlutterInjector
import io.flutter.view.TextureRegistry.SurfaceProducer

/**
 * One texture's playback: ExoPlayer decode -> [NeoVapRenderer] alpha-composite
 * -> Flutter [SurfaceProducer]. Created per `allocateTexture`; the GL/decoder
 * stack is built lazily on the first `play` (which supplies the asset whose
 * `vapc` geometry sizes everything).
 *
 * All methods are called on the main thread (from the method channel).
 */
class NeoVapPlayer(
    private val context: Context,
    private val producer: SurfaceProducer,
    private val emit: (event: String, message: String?) -> Unit,
) {
    val textureId: Long get() = producer.id()

    private var player: ExoPlayer? = null
    private var renderer: NeoVapRenderer? = null

    private fun ensureInitialized(assetPath: String) {
        // ponytail: sized once from the first asset's vapc — safe since intro/loop
        // always share geometry. A later asset with different geometry on the same
        // texture would mis-crop; recreate the renderer per-play if that happens.
        if (player != null) return

        val key = lookupKey(assetPath)
        val info = VapcInfo.parse(context.assets.open(key).use { it.readBytes() })

        producer.setSize(info.width, info.height)
        val r = NeoVapRenderer(info) { emit("firstFrame", null) }
        val inputSurface = r.awaitInputSurface()
        renderer = r

        // Bind the output surface now and on every resume; never cache it.
        r.onOutputSurfaceAvailable(producer.surface)
        producer.setCallback(object : SurfaceProducer.Callback {
            override fun onSurfaceAvailable() = r.onOutputSurfaceAvailable(producer.surface)
            override fun onSurfaceCleanup() = r.onOutputSurfaceDestroyed()
        })

        player = ExoPlayer.Builder(context).build().apply {
            setVideoSurface(inputSurface)
            addListener(object : Player.Listener {
                override fun onPlaybackStateChanged(state: Int) {
                    // Only reached for a genuinely finite play; the intro→loop
                    // sequence never ends (the loop item is REPEAT_MODE_ONE).
                    if (state == Player.STATE_ENDED) emit("ended", null)
                }

                override fun onMediaItemTransition(item: MediaItem?, reason: Int) {
                    // Auto-advanced from the intro (index 0) to the loop (index
                    // 1): loop that item forever. Gapless — ExoPlayer buffered it
                    // while the intro played.
                    if (currentMediaItemIndex == 1) repeatMode = Player.REPEAT_MODE_ONE
                }

                override fun onPlayerError(error: PlaybackException) {
                    emit("error", error.message ?: error.errorCodeName)
                }
            })
        }
    }

    /**
     * Play [assetPath]. With [nextAsset], play [assetPath] once then loop
     * [nextAsset] forever, chained gaplessly by the playlist (the intro→loop
     * case). Otherwise [repeat] == -1 loops [assetPath] forever, else once.
     */
    fun play(assetPath: String, repeat: Int, nextAsset: String?) {
        ensureInitialized(assetPath)
        val p = player ?: return
        if (nextAsset != null) {
            p.repeatMode = Player.REPEAT_MODE_OFF // intro once; loop set on transition
            p.setMediaItems(
                listOf(
                    MediaItem.fromUri(assetUri(assetPath)),
                    MediaItem.fromUri(assetUri(nextAsset)),
                ),
            )
        } else {
            p.repeatMode =
                if (repeat == LOOP_FOREVER) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
            p.setMediaItem(MediaItem.fromUri(assetUri(assetPath)))
        }
        p.prepare()
        p.playWhenReady = true
    }

    fun stop() {
        player?.run {
            playWhenReady = false
            seekTo(0)
        }
    }

    fun dispose() {
        player?.release()
        player = null
        renderer?.release()
        renderer = null
        producer.setCallback(null)
        producer.release()
    }

    private fun assetUri(assetPath: String): Uri = Uri.parse("asset:///${lookupKey(assetPath)}")

    private fun lookupKey(assetPath: String): String =
        FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(assetPath)

    companion object {
        internal const val LOOP_FOREVER = -1
    }
}
