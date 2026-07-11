package xyz.neosapien.neo_vap

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse

/** Native vapc parser tests — mirror of test/vapc_test.dart. */
internal class VapcTest {
    private fun box(type: String, payload: ByteArray): ByteArray {
        val size = 8 + payload.size
        val out = ByteArrayOutputStream()
        out.write(ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(size).array())
        out.write(type.toByteArray(Charsets.US_ASCII))
        out.write(payload)
        return out.toByteArray()
    }

    private fun mp4(json: String, includeVapc: Boolean = true): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(box("ftyp", "isom".toByteArray()))
        if (includeVapc) out.write(box("vapc", json.toByteArray(Charsets.UTF_8)))
        out.write(box("mdat", byteArrayOf(0, 0, 0, 0)))
        return out.toByteArray()
    }

    // Exact info payload from active_mode_intro_vap.mp4.
    private val realJson =
        """{"info":{"v":2,"f":49,"w":1000,"h":1000,"fps":25,"videoW":1504,""" +
            """"videoH":1008,"aFrame":[1004,0,500,500],"rgbFrame":[0,0,1000,1000],""" +
            """"isVapx":0,"orien":0}}"""

    @Test
    fun parsesRealAtom() {
        val info = VapcInfo.parse(mp4(realJson))
        assertEquals(49, info.frameCount)
        assertEquals(1000, info.width)
        assertEquals(1504, info.videoWidth)
        assertEquals(VapcRect(0, 0, 1000, 1000), info.rgbFrame)
        assertEquals(VapcRect(1004, 0, 500, 500), info.aFrame)
        assertEquals(1.0, info.aspectRatio)
        assertFalse(info.isVapx)
    }

    @Test
    fun throwsWhenNoVapcAtom() {
        assertFailsWith<VapcParseException> { VapcInfo.parse(mp4("", includeVapc = false)) }
    }

    @Test
    fun wrapsNonJsonPayload() {
        assertFailsWith<VapcParseException> { VapcInfo.parse(mp4("not json")) }
    }
}
