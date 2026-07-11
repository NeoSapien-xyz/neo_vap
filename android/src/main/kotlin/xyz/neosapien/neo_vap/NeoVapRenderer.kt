package xyz.neosapien.neo_vap

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.CountDownLatch

/**
 * Composites a side-by-side VAP frame into a transparent [Surface].
 *
 * ExoPlayer decodes into [inputSurface] (an external-OES [SurfaceTexture]); on
 * each frame a GLES2 shader samples the colour region and the alpha region
 * (per the `vapc` rects), premultiplies, and draws into the Flutter
 * [SurfaceProducer] surface. All GL work runs on one dedicated thread.
 *
 * Y-orientation note: the [SurfaceTexture] transform matrix handles the input
 * flip; the output quad is authored bottom-left origin. If frames appear
 * upside down on device, flip the quad's texcoord V (single-line change below).
 */
class NeoVapRenderer(
    private val info: VapcInfo,
    private val onFirstFrame: () -> Unit,
) {
    private val thread = HandlerThread("neo_vap_gl").apply { start() }
    private val handler = Handler(thread.looper)

    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglConfig: EGLConfig? = null
    private var windowSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var pbufferSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    private var oesTexId = 0
    private var program = 0
    private lateinit var surfaceTexture: SurfaceTexture
    lateinit var inputSurface: Surface
        private set

    private var outputSurface: Surface? = null
    private val stMatrix = FloatArray(16)
    private var firstFrameSent = false
    private var released = false

    // Fullscreen quad: pos(-1..1) + texcoord(0..1). Texcoord V is flipped so the
    // content renders upright into the output surface.
    private val quad: FloatBuffer = ByteBuffer
        .allocateDirect(16 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        .apply {
            put(
                floatArrayOf(
                    // x, y,   u, v
                    -1f, -1f, 0f, 1f,
                    1f, -1f, 1f, 1f,
                    -1f, 1f, 0f, 0f,
                    1f, 1f, 1f, 0f,
                ),
            )
            position(0)
        }

    /** Block until the input [Surface] exists, then hand it to the caller. */
    fun awaitInputSurface(): Surface {
        val latch = CountDownLatch(1)
        var error: Throwable? = null
        handler.post {
            // finally-countDown so a GL init failure surfaces as an exception on
            // the caller instead of ANR-ing the main thread on the latch; catch
            // so it doesn't crash the render thread as an uncaught exception.
            try {
                initGl()
            } catch (t: Throwable) {
                error = t
            } finally {
                latch.countDown()
            }
        }
        latch.await()
        error?.let { throw RuntimeException("neo_vap GL init failed: ${it.message}", it) }
        return inputSurface
    }

    /** (Re)bind the Flutter output surface and redraw the latest frame. */
    fun onOutputSurfaceAvailable(surface: Surface) {
        handler.post {
            outputSurface = surface
            createWindowSurface()
            drawFrame()
        }
    }

    /** Output surface went away (app backgrounded); stop drawing to it. */
    fun onOutputSurfaceDestroyed() {
        handler.post {
            destroyWindowSurface()
            outputSurface = null
        }
    }

    fun release() {
        handler.post {
            released = true
            // Bind the pbuffer so GL deletes are valid even if the window surface
            // was already destroyed (background teardown).
            if (pbufferSurface != EGL14.EGL_NO_SURFACE) {
                EGL14.eglMakeCurrent(eglDisplay, pbufferSurface, pbufferSurface, eglContext)
            }
            if (::surfaceTexture.isInitialized) surfaceTexture.release()
            if (::inputSurface.isInitialized) inputSurface.release()
            if (program != 0) GLES20.glDeleteProgram(program)
            if (oesTexId != 0) GLES20.glDeleteTextures(1, intArrayOf(oesTexId), 0)
            destroyWindowSurface()
            if (pbufferSurface != EGL14.EGL_NO_SURFACE) {
                EGL14.eglDestroySurface(eglDisplay, pbufferSurface)
                pbufferSurface = EGL14.EGL_NO_SURFACE
            }
            EGL14.eglMakeCurrent(
                eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT,
            )
            if (eglContext != EGL14.EGL_NO_CONTEXT) {
                EGL14.eglDestroyContext(eglDisplay, eglContext)
            }
            if (eglDisplay != EGL14.EGL_NO_DISPLAY) EGL14.eglTerminate(eglDisplay)
            thread.quitSafely()
        }
    }

    // --- render thread only below ---

    private fun initGl() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        EGL14.eglInitialize(eglDisplay, IntArray(2), 0, IntArray(2), 1)
        val configAttrs = intArrayOf(
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8, // transparent output
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        EGL14.eglChooseConfig(eglDisplay, configAttrs, 0, configs, 0, 1, IntArray(1), 0)
        eglConfig = configs[0]
        eglContext = EGL14.eglCreateContext(
            eglDisplay, eglConfig, EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
        )
        // Need a current context to create the OES texture + program. Keep a 1x1
        // pbuffer as the fallback draw surface whenever no window surface is
        // bound (before the first, and after background teardown).
        pbufferSurface = EGL14.eglCreatePbufferSurface(
            eglDisplay, eglConfig,
            intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0,
        )
        EGL14.eglMakeCurrent(eglDisplay, pbufferSurface, pbufferSurface, eglContext)

        oesTexId = IntArray(1).also { GLES20.glGenTextures(1, it, 0) }[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTexId)
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE,
        )

        program = buildProgram()

        surfaceTexture = SurfaceTexture(oesTexId).apply {
            setDefaultBufferSize(info.videoWidth, info.videoHeight)
            setOnFrameAvailableListener { handler.post { drawFrame() } }
        }
        inputSurface = Surface(surfaceTexture)
    }

    private fun createWindowSurface() {
        val surface = outputSurface ?: return
        destroyWindowSurface()
        windowSurface = EGL14.eglCreateWindowSurface(
            eglDisplay, eglConfig, surface, intArrayOf(EGL14.EGL_NONE), 0,
        )
    }

    private fun destroyWindowSurface() {
        if (windowSurface != EGL14.EGL_NO_SURFACE) {
            EGL14.eglDestroySurface(eglDisplay, windowSurface)
            windowSurface = EGL14.EGL_NO_SURFACE
        }
    }

    private fun drawFrame() {
        if (released) return
        // Always consume the newest frame to keep the SurfaceTexture unblocked,
        // even if we have no output surface to draw into yet.
        surfaceTexture.updateTexImage()
        surfaceTexture.getTransformMatrix(stMatrix)
        if (windowSurface == EGL14.EGL_NO_SURFACE) return

        EGL14.eglMakeCurrent(eglDisplay, windowSurface, windowSurface, eglContext)
        GLES20.glViewport(0, 0, info.width, info.height)
        GLES20.glClearColor(0f, 0f, 0f, 0f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        GLES20.glUseProgram(program)
        val aPos = GLES20.glGetAttribLocation(program, "aPos")
        val aTex = GLES20.glGetAttribLocation(program, "aTex")
        quad.position(0)
        GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 16, quad)
        GLES20.glEnableVertexAttribArray(aPos)
        quad.position(2)
        GLES20.glVertexAttribPointer(aTex, 2, GLES20.GL_FLOAT, false, 16, quad)
        GLES20.glEnableVertexAttribArray(aTex)

        GLES20.glUniformMatrix4fv(
            GLES20.glGetUniformLocation(program, "uSTMatrix"), 1, false, stMatrix, 0,
        )
        GLES20.glUniform2f(
            GLES20.glGetUniformLocation(program, "uVideoSize"),
            info.videoWidth.toFloat(), info.videoHeight.toFloat(),
        )
        GLES20.glUniform4f(
            GLES20.glGetUniformLocation(program, "uRgbRect"),
            info.rgbFrame.x.toFloat(), info.rgbFrame.y.toFloat(),
            info.rgbFrame.w.toFloat(), info.rgbFrame.h.toFloat(),
        )
        GLES20.glUniform4f(
            GLES20.glGetUniformLocation(program, "uAlphaRect"),
            info.aFrame.x.toFloat(), info.aFrame.y.toFloat(),
            info.aFrame.w.toFloat(), info.aFrame.h.toFloat(),
        )
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTexId)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "uTex"), 0)

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        EGL14.eglSwapBuffers(eglDisplay, windowSurface)

        if (!firstFrameSent) {
            firstFrameSent = true
            onFirstFrame()
        }
    }

    private fun buildProgram(): Int {
        val vs = compile(GLES20.GL_VERTEX_SHADER, VERTEX_SHADER)
        val fs = compile(GLES20.GL_FRAGMENT_SHADER, FRAGMENT_SHADER)
        val prog = GLES20.glCreateProgram()
        GLES20.glAttachShader(prog, vs)
        GLES20.glAttachShader(prog, fs)
        GLES20.glLinkProgram(prog)
        val linked = IntArray(1)
        GLES20.glGetProgramiv(prog, GLES20.GL_LINK_STATUS, linked, 0)
        check(linked[0] == GLES20.GL_TRUE) {
            "neo_vap program link failed: ${GLES20.glGetProgramInfoLog(prog)}"
        }
        return prog
    }

    private fun compile(type: Int, src: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, src)
        GLES20.glCompileShader(shader)
        val ok = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, ok, 0)
        check(ok[0] == GLES20.GL_TRUE) {
            "neo_vap shader compile failed: ${GLES20.glGetShaderInfoLog(shader)}"
        }
        return shader
    }

    companion object {
        private const val VERTEX_SHADER = """
            attribute vec2 aPos;
            attribute vec2 aTex;
            varying vec2 vTex;
            void main() {
                vTex = aTex;
                gl_Position = vec4(aPos, 0.0, 1.0);
            }
        """

        // Samples the colour region + alpha region of the decoded frame and
        // outputs premultiplied RGBA. The alpha region may be stored at a
        // different (e.g. half) scale; normalising by each rect handles it.
        private const val FRAGMENT_SHADER = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            uniform samplerExternalOES uTex;
            uniform mat4 uSTMatrix;
            uniform vec2 uVideoSize;
            uniform vec4 uRgbRect;
            uniform vec4 uAlphaRect;
            varying vec2 vTex;

            vec2 sampleUV(vec4 rect) {
                vec2 px = rect.xy + vTex * rect.zw;
                vec2 norm = px / uVideoSize;
                return (uSTMatrix * vec4(norm, 0.0, 1.0)).xy;
            }
            void main() {
                vec3 color = texture2D(uTex, sampleUV(uRgbRect)).rgb;
                float alpha = texture2D(uTex, sampleUV(uAlphaRect)).r;
                gl_FragColor = vec4(color * alpha, alpha);
            }
        """
    }
}
