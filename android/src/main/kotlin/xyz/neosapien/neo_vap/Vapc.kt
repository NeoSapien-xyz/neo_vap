package xyz.neosapien.neo_vap

import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Integer pixel rectangle `[x, y, w, h]` from a `vapc` atom. */
data class VapcRect(val x: Int, val y: Int, val w: Int, val h: Int)

/**
 * Parsed `vapc` atom (the native mirror of `lib/src/vapc.dart`). The native
 * side reads the asset for ExoPlayer anyway, so it parses its own crop rects
 * rather than threading them through the method channel.
 */
data class VapcInfo(
    val version: Int,
    val frameCount: Int,
    val width: Int,
    val height: Int,
    val fps: Int,
    val videoWidth: Int,
    val videoHeight: Int,
    val rgbFrame: VapcRect,
    val aFrame: VapcRect,
    val isVapx: Boolean,
    val orientation: Int,
) {
    /** Content aspect ratio (width / height). */
    val aspectRatio: Double get() = if (height == 0) 1.0 else width.toDouble() / height

    companion object {
        fun parse(bytes: ByteArray): VapcInfo {
            try {
                val info = JSONObject(extractVapcJson(bytes)).getJSONObject("info")
                return VapcInfo(
                    version = info.getInt("v"),
                    frameCount = info.getInt("f"),
                    width = info.getInt("w"),
                    height = info.getInt("h"),
                    fps = info.getInt("fps"),
                    videoWidth = info.getInt("videoW"),
                    videoHeight = info.getInt("videoH"),
                    rgbFrame = rect(info.getJSONArray("rgbFrame")),
                    aFrame = rect(info.getJSONArray("aFrame")),
                    isVapx = info.optInt("isVapx", 0) != 0,
                    orientation = info.optInt("orien", 0),
                )
            } catch (e: VapcParseException) {
                throw e
            } catch (e: Exception) {
                throw VapcParseException("malformed vapc atom: $e")
            }
        }

        private fun rect(a: JSONArray): VapcRect {
            if (a.length() < 4) throw VapcParseException("rect needs 4 elements")
            return VapcRect(a.getInt(0), a.getInt(1), a.getInt(2), a.getInt(3))
        }

        /**
         * Walk top-level mp4 boxes `[uint32 size][4-char type][payload]` and
         * return the `vapc` box's UTF-8 JSON. size==1 -> 64-bit largesize,
         * size==0 -> extends to EOF.
         */
        private fun extractVapcJson(bytes: ByteArray): String {
            val bb = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
            var offset = 0
            while (offset + 8 <= bytes.size) {
                var size = bb.getInt(offset).toLong() and 0xFFFFFFFFL
                var header = 8
                when (size) {
                    1L -> {
                        if (offset + 16 > bytes.size) break
                        size = bb.getLong(offset + 8)
                        header = 16
                    }
                    0L -> size = (bytes.size - offset).toLong()
                }
                if (size < header || offset + size > bytes.size) {
                    throw VapcParseException("corrupt mp4 box at $offset (size $size)")
                }
                val type = String(bytes, offset + 4, 4, Charsets.US_ASCII)
                if (type == "vapc") {
                    val start = offset + header
                    val end = (offset + size).toInt()
                    return String(bytes, start, end - start, Charsets.UTF_8)
                        .trim { it <= ' ' } // drop trailing NUL box padding + whitespace
                }
                offset += size.toInt()
            }
            throw VapcParseException("no vapc atom found (not a VAP mp4?)")
        }
    }
}

class VapcParseException(message: String) : Exception(message)
