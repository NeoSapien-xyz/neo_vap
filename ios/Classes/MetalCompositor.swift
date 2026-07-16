import Metal
import simd

/// Crop geometry pushed to the fragment shader. All three are `float4` so the
/// Swift and MSL struct layouts are alignment-identical (float4 aligns to 16);
/// `videoSize` only uses `.xy`.
struct NeoVapRects {
  var videoSize: simd_float4
  var rgbRect: simd_float4
  var aRect: simd_float4
}

/// Process-wide Metal device + command queue + composite pipeline, compiled
/// exactly once. The pipeline (and its shader compile — the slow part) is what
/// `NeoVap.prewarm()` warms off the main thread so the first real play skips the
/// cold PSO-compile stall. Mirrors the Android GL-program warm.
///
/// `shared` is a lazy `static let` (thread-safe, once-only); first access builds
/// and compiles. Returns nil only on a device with no Metal / a shader-compile
/// failure — callers no-op, matching the Android "first play pays cold start"
/// fallback rather than crashing.
final class MetalCompositor {
  static let shared: MetalCompositor? = MetalCompositor()

  let device: MTLDevice
  let queue: MTLCommandQueue
  let pipeline: MTLRenderPipelineState

  private init?() {
    guard
      let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue()
    else { return nil }
    do {
      let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
      let desc = MTLRenderPipelineDescriptor()
      desc.vertexFunction = library.makeFunction(name: "neovap_vertex")
      desc.fragmentFunction = library.makeFunction(name: "neovap_fragment")
      // Output is a BGRA CVPixelBuffer (non-negotiable for FlutterTexture on iOS
      // per flutter#147242) holding premultiplied RGBA.
      desc.colorAttachments[0].pixelFormat = .bgra8Unorm
      self.pipeline = try device.makeRenderPipelineState(descriptor: desc)
    } catch {
      NSLog("neo_vap: Metal pipeline build failed: \(error)")
      return nil
    }
    self.device = device
    self.queue = queue
  }

  /// Runtime-compiled composite shader — mirror of `alpha_composite.frag` on
  /// Android. Compiling from source (vs a prebuilt .metallib) keeps the podspec
  /// free of resource-bundle plumbing and mirrors Android's string-source GLSL;
  /// prewarm pays the compile once, off-main.
  ///
  /// The input texture is a BGRA `CVPixelBuffer` (VideoToolbox already did
  /// YUV→BGRA), so `.rgb`/`.r` swizzle to the correct channels regardless of the
  /// BGRA memory order. The alpha region is grayscale → its red channel is alpha.
  private static let shaderSource = """
  #include <metal_stdlib>
  using namespace metal;

  struct VOut {
    float4 pos [[position]];
    float2 uv;
  };

  // Fullscreen quad, triangle-strip. uv is top-left origin to match the source
  // CVPixelBuffer (image y-down) — no flip needed on Metal (unlike GL's OES path).
  vertex VOut neovap_vertex(uint vid [[vertex_id]]) {
    float2 pos[4] = { float2(-1, 1), float2(1, 1), float2(-1, -1), float2(1, -1) };
    float2 uv[4]  = { float2(0, 0),  float2(1, 0), float2(0, 1),   float2(1, 1) };
    VOut o;
    o.pos = float4(pos[vid], 0, 1);
    o.uv = uv[vid];
    return o;
  }

  struct Rects {
    float4 videoSize; // .xy = decoded frame px
    float4 rgbRect;   // x,y,w,h in source px
    float4 aRect;
  };

  fragment float4 neovap_fragment(VOut in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]],
                                  constant Rects& r [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 rgbUV = (r.rgbRect.xy + in.uv * r.rgbRect.zw) / r.videoSize.xy;
    float2 aUV   = (r.aRect.xy   + in.uv * r.aRect.zw)   / r.videoSize.xy;
    float3 color = tex.sample(s, rgbUV).rgb;
    float alpha  = tex.sample(s, aUV).r;
    return float4(color * alpha, alpha); // premultiplied
  }
  """
}
