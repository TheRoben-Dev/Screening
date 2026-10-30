import MetalKit

/// The GPU side of the capture animation. The shader compiles from source at launch, which
/// macOS can always do, so building the app doesn't need Xcode's separate Metal Toolchain.
final class RefractionRenderer {
    static let shared = RefractionRenderer()

    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let vertex = library.makeFunction(name: "fullScreenVertex"),
              let fragment = library.makeFunction(name: "captureRefraction")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }

        self.device = device
        self.pipeline = pipeline
        self.sampler = sampler
    }

    private static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 rect;   // The capture, in the screen's top-down points.
        float2 origin; // Where the pointer was: the disturbance starts here.
        float2 size;   // The screen, in points.
        float radius;
        float time;
    };

    struct Varyings {
        float4 position [[position]];
        float2 uv;
    };

    vertex Varyings fullScreenVertex(uint id [[vertex_id]]) {
        float2 uv = float2((id << 1) & 2, id & 2);
        Varyings out;
        out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
        out.uv = uv;
        return out;
    }

    // Signed distance to a rounded rectangle: negative inside, positive outside.
    static float roundedRectDistance(float2 p, float2 center, float2 halfSize, float radius) {
        float2 q = abs(p - center) - halfSize + radius;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    }

    // The screen is treated as the surface of a liquid. Everything visible comes from this one
    // height field: the bending, the light and the shade are all consequences of its slope, so
    // nothing is drawn on top of the screen and flat areas are untouched pixels.
    static float surfaceHeight(float2 p, constant Uniforms &u) {
        float2 center = u.rect.xy + u.rect.zw * 0.5;
        float2 halfSize = u.rect.zw * 0.5;
        float smallest = min(halfSize.x, halfSize.y);
        float corner = min(u.radius, smallest);
        float d = roundedRectDistance(p, center, halfSize, corner);
        float inner = min(roundedRectDistance(p, center, halfSize, max(corner, min(140.0, smallest))), 0.0);

        // The disturbance reaches each spot a moment after leaving the pointer.
        float t = u.time - length(p - u.origin) / 4200.0;
        if (t <= 0.0) return 0.0;

        // Liquid never holds a straight line: the fronts wander as they spread.
        float2 fromCenter = p - center;
        float angle = atan2(fromCenter.y, fromCenter.x);
        float along = (fromCenter.x + fromCenter.y) * 0.011;
        float wander = sin(angle * 3.0 + 1.3 + t * 3.0) + 0.6 * sin(angle * 7.0 - t * 5.0) + 0.8 * sin(along + t * 4.0);

        float height = 0.0;
        for (int i = 0; i < 2; i++) {
            float local = t - float(i) * 0.13;
            if (local <= 0.0) continue;
            float gain = i == 0 ? 1.0 : 0.42;
            float reach = 1.0 - exp(-local * 2.8);
            // Spreading out thins a wave, so it weakens as it travels and dies away by itself.
            float life = smoothstep(0.0, 0.05, local) * exp(-local * 4.6) * gain;
            float width = 26.0 + local * 70.0;

            float x = (d - reach * 210.0 - wander * local * 14.0) / width;
            height += 8.0 * life * exp(-x * x) * cos(x * 2.0);

            float y = (inner + reach * 150.0 + wander * local * 10.0) / width;
            height += 6.0 * life * exp(-y * y) * cos(y * 2.0);
        }

        // The captured area dips and recovers, as if it had just been pressed.
        float press = exp(-t * 7.0) * smoothstep(0.0, 0.04, t);
        height -= 4.0 * press * smoothstep(0.0, -46.0, d);
        return height;
    }

    fragment float4 captureRefraction(Varyings in [[stage_in]],
                                      constant Uniforms &u [[buffer(0)]],
                                      texture2d<float> screen [[texture(0)]],
                                      sampler s [[sampler(0)]]) {
        float2 pos = in.uv * u.size;

        const float2 e = float2(1.5, 0.0);
        float2 slope = float2(surfaceHeight(pos + e.xy, u) - surfaceHeight(pos - e.xy, u),
                              surfaceHeight(pos + e.yx, u) - surfaceHeight(pos - e.yx, u)) / (2.0 * e.x);
        float steepness = length(slope);

        // Where the surface is flat this pixel is exactly the frozen screen, so fading it out
        // leaves no edge: there's no shape here for the eye to read as an overlay.
        float alpha = smoothstep(0.0015, 0.02, steepness);
        if (alpha <= 0.0) return float4(0.0);

        // Refraction: light bends with the slope, and each color by a slightly different amount.
        float2 bend = -slope * 58.0;
        float3 color = float3(screen.sample(s, (pos + bend * 1.14) / u.size).r,
                              screen.sample(s, (pos + bend) / u.size).g,
                              screen.sample(s, (pos + bend * 0.86) / u.size).b);

        // Lit from above like everything on a Mac: slopes facing the light brighten and slopes
        // facing away darken, which is what gives the surface its volume.
        float3 normal = normalize(float3(-slope * 2.2, 1.0));
        float3 light = normalize(float3(-0.35, -0.75, 0.56));
        float shade = dot(normal, light) - light.z;
        color *= 1.0 + shade * 0.3;

        // A glint only where the surface actually tilts toward the light.
        float3 halfway = normalize(light + float3(0.0, 0.0, 1.0));
        float glint = pow(max(dot(normal, halfway), 0.0), 90.0) * smoothstep(0.02, 0.2, steepness);
        color += float3(0.94, 0.97, 1.0) * glint * 0.3;

        return float4(saturate(color) * alpha, alpha);
    }
    """#
}

/// Draws the shader over a frozen screen, on a transparent layer.
final class RefractionView: MTKView, MTKViewDelegate {
    private struct Uniforms {
        var rect: SIMD4<Float>
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
        var radius: Float
        var time: Float
    }

    private let renderer: RefractionRenderer
    private let texture: MTLTexture
    private let commandQueue: MTLCommandQueue
    private let rect: CGRect
    private let origin: CGPoint
    private let radius: CGFloat
    private var startTime: CFTimeInterval?

    init?(backdrop: Backdrop, rect: CGRect, origin: CGPoint, radius: CGFloat) {
        guard let renderer = RefractionRenderer.shared,
              let queue = renderer.device.makeCommandQueue(),
              let texture = try? MTKTextureLoader(device: renderer.device).newTexture(
                  cgImage: backdrop.image, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
        else { return nil }
        self.renderer = renderer
        self.texture = texture
        commandQueue = queue
        self.rect = rect
        self.origin = origin
        self.radius = radius
        super.init(frame: CGRect(origin: .zero, size: backdrop.frame.size), device: renderer.device)

        delegate = self
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        preferredFramesPerSecond = 120
        layer?.isOpaque = false
        // Match the picture's color space, or the bent pixels wouldn't line up with the live screen.
        (layer as? CAMetalLayer)?.colorspace = backdrop.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let commands = commandQueue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        // The clock starts on the first frame the user can actually see.
        let now = CACurrentMediaTime()
        if startTime == nil { startTime = now }

        var uniforms = Uniforms(
            rect: SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height)),
            origin: SIMD2(Float(origin.x), Float(origin.y)),
            size: SIMD2(Float(bounds.width), Float(bounds.height)),
            radius: Float(radius),
            time: Float(now - (startTime ?? now)))

        encoder.setRenderPipelineState(renderer.pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(renderer.sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
