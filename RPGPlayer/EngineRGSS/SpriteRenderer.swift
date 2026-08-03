// RPGPlayer/EngineRGSS/SpriteRenderer.swift
//
// MetalKit-based renderer for RGSS sprites.
// M1b: renders a single sprite texture full-screen as proof-of-concept.
// M5:  added per-frame FPS measurement (logged every 2s for profiling).
// Future milestones will add layered rendering, viewports, z-ordering, etc.

import MetalKit
import Metal

// ---------------------------------------------------------------------------
// MARK: - SpriteRenderer
// ---------------------------------------------------------------------------

/// Owns the Metal device, render pipeline, and current sprite texture.
/// Conforms to `MTKViewDelegate` for the draw loop.
final class SpriteRenderer: NSObject, MTKViewDelegate {

    // MARK: - Metal state

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private let textureLoader: MTKTextureLoader

    // MARK: - Scene state

    /// The texture currently queued for rendering.
    /// Updated from any thread; read on draw thread (both go through Metal's
    /// internal synchronisation in MTKView for M1b single-texture use).
    private(set) var currentTexture: MTLTexture?

    /// M6.2: Sprite position in NDC (center). Default (0,0) = screen center.
    /// Updated from Ruby (Game_Player movement) via setSpritePosition.
    private(set) var spritePosition: SIMD2<Float> = SIMD2<Float>(0, 0)

    /// M6.2: Sprite size in NDC. Default (2,2) = full screen (M1b behaviour).
    private(set) var spriteSize: SIMD2<Float> = SIMD2<Float>(2, 2)

    /// M6.2: Uniform buffer for the vertex shader (SpriteUniforms).
    private var uniformBuffer: MTLBuffer?

    // MARK: - M5: FPS profiling

    /// Frame counter reset every FPS report interval.
    private var frameCount: Int = 0
    /// CACurrentMediaTime at last FPS log.
    private var lastReportTime: CFTimeInterval = CACurrentMediaTime()
    /// Report FPS every N seconds.
    private let fpsReportInterval: CFTimeInterval = 2.0
    /// Last measured FPS (readable from outside for debugging).
    private(set) var measuredFPS: Double = 0.0

    // MARK: - Init

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            print("[SpriteRenderer] ❌ makeCommandQueue() failed")
            return nil
        }
        self.commandQueue = queue
        self.textureLoader = MTKTextureLoader(device: device)
        super.init()
        buildPipeline()
        buildUniformBuffer()
    }

    /// M6.2: Create the uniform buffer for the vertex shader (SpriteUniforms).
    /// 16 bytes = float2 position + float2 size.
    private func buildUniformBuffer() {
        guard let buf = device.makeBuffer(length: 16, options: .storageModeShared) else {
            print("[SpriteRenderer] ❌ makeBuffer(uniform) failed")
            return
        }
        buf.label = "RGSS Sprite Uniforms"
        uniformBuffer = buf
    }

    // MARK: - Pipeline setup

    private func buildPipeline() {
        // The default Metal library contains all .metal files in the target.
        guard let library = device.makeDefaultLibrary() else {
            print("[SpriteRenderer] ❌ makeDefaultLibrary() failed — no .metal files compiled")
            return
        }

        guard
            let vertFn = library.makeFunction(name: "sprite_vertex"),
            let fragFn = library.makeFunction(name: "sprite_fragment")
        else {
            print("[SpriteRenderer] ❌ Missing shader functions sprite_vertex/sprite_fragment")
            return
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.label = "RGSS Sprite Pipeline"
        desc.vertexFunction   = vertFn
        desc.fragmentFunction = fragFn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm  // matches MTKView default

        // Standard source-over alpha blending (RGSS blend_type 0)
        let ca = desc.colorAttachments[0]!
        ca.isBlendingEnabled             = true
        ca.sourceRGBBlendFactor          = .sourceAlpha
        ca.destinationRGBBlendFactor     = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor        = .one
        ca.destinationAlphaBlendFactor   = .oneMinusSourceAlpha
        ca.rgbBlendOperation             = .add
        ca.alphaBlendOperation           = .add

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
            print("[SpriteRenderer] ✅ Metal pipeline ready (bgra8Unorm, alpha-blend)")
        } catch {
            print("[SpriteRenderer] ❌ Pipeline compile error: \(error)")
        }
    }

    // MARK: - Texture loading

    /// Shared MTKTextureLoader options.
    private var textureLoadOptions: [MTKTextureLoader.Option: Any] {
        [.textureUsage: MTLTextureUsage.shaderRead.rawValue,
         .SRGB: false]
    }

    /// Load a texture by bundle resource name (e.g. `"test.png"`).
    /// M4: All error paths are fully caught — uses checkerboard placeholder instead of crashing.
    func loadTexture(named name: String) {
        let ext  = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension

        guard let url = Bundle.main.url(
            forResource: base,
            withExtension: ext.isEmpty ? nil : ext
        ) else {
            print("[SpriteRenderer] ℹ️  '\(name)' not found in bundle — using placeholder")
            currentTexture = makePlaceholderTexture(reason: "not-found: \(name)")
            return
        }

        do {
            currentTexture = try textureLoader.newTexture(URL: url, options: textureLoadOptions)
            print("[SpriteRenderer] ✅ Texture loaded from bundle: \(name)")
        } catch {
            // M4: Crash guard — never crash on a bad image file.
            print("[SpriteRenderer] ⚠️  Decode failed for '\(name)': \(error.localizedDescription) — using placeholder")
            currentTexture = makePlaceholderTexture(reason: "decode-error: \(name)")
        }
    }

    /// Load a texture from an absolute file-system URL (e.g. game sandbox asset path).
    /// M4: Crash guard identical to loadTexture(named:) — placeholder on any failure.
    func loadTextureFromURL(at fileURL: URL) {
        let fileName = fileURL.lastPathComponent

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("[SpriteRenderer] ℹ️  File not found: \(fileURL.path) — using placeholder")
            currentTexture = makePlaceholderTexture(reason: "not-found: \(fileName)")
            return
        }

        do {
            currentTexture = try textureLoader.newTexture(URL: fileURL, options: textureLoadOptions)
            print("[SpriteRenderer] ✅ Texture loaded from sandbox: \(fileName)")
        } catch {
            // M4: Log the exact file name so it's easy to identify broken assets.
            print("[SpriteRenderer] ⚠️  Decode failed for '\(fileName)': \(error.localizedDescription) — using placeholder")
            currentTexture = makePlaceholderTexture(reason: "decode-error: \(fileName)")
        }
    }

    // MARK: - M6.2: Sprite transform

    /// Set the sprite's position and size in NDC.
    /// - Parameters:
    ///   - x: NDC X (-1 = left edge, +1 = right edge, 0 = center).
    ///   - y: NDC Y (-1 = bottom, +1 = top, 0 = center).
    ///   - width:  NDC width  (2 = full screen width).
    ///   - height: NDC height (2 = full screen height).
    ///
    /// M6.2: called from Ruby (Game_Player movement) to move the player sprite.
    /// Thread: main thread (called from advanceFrame via CADisplayLink).
    func setSpritePosition(x: Float, y: Float, width: Float, height: Float) {
        spritePosition = SIMD2<Float>(x, y)
        spriteSize     = SIMD2<Float>(width, height)
    }

    /// Procedural 64×64 checkerboard placeholder texture.
    /// M4: Used whenever an image fails to load — warm orange / dark teal palette.
    /// The `reason` parameter is logged so broken assets are easy to identify.
    private func makePlaceholderTexture(reason: String = "") -> MTLTexture? {
        if !reason.isEmpty {
            print("[SpriteRenderer] 🖼  Placeholder reason: \(reason)")
        }
        let size = 64
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width:  size,
            height: size,
            mipmapped: false
        )
        desc.usage = .shaderRead

        guard let tex = device.makeTexture(descriptor: desc) else { return nil }

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let light = ((x / 8) + (y / 8)) % 2 == 0
                // Light cell: warm orange  Dark cell: dark teal
                pixels[i + 0] = light ? 240 : 30   // R
                pixels[i + 1] = light ? 140 : 90   // G
                pixels[i + 2] = light ?  30 : 110  // B
                pixels[i + 3] = 255                 // A (fully opaque)
            }
        }

        tex.replace(
            region:     MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0,
            withBytes:  pixels,
            bytesPerRow: size * 4
        )
        print("[SpriteRenderer] ✅ Placeholder checkerboard texture ready (\(size)×\(size))")
        return tex
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // M1b: full-screen quad, no projection — nothing to update.
        // Future: update projection matrix and RGSS Screen.width/height here.
    }

    func draw(in view: MTKView) {
        guard
            let pipeline        = pipelineState,
            let passDescriptor  = view.currentRenderPassDescriptor,
            let drawable        = view.currentDrawable,
            let commandBuffer   = commandQueue.makeCommandBuffer()
        else { return }

        commandBuffer.label = "RGSS Frame"

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            commandBuffer.commit()
            return
        }
        encoder.label = "RGSS Sprite Pass"

        encoder.setRenderPipelineState(pipeline)

        if let texture = currentTexture, let uniformBuffer = uniformBuffer {
            // M6.2: Write current sprite transform into the shared uniform buffer.
            // Layout matches SpriteUniforms in Shaders.metal: float2 position, float2 size.
            let ptr = uniformBuffer.contents().assumingMemoryBound(to: Float.self)
            ptr[0] = spritePosition.x
            ptr[1] = spritePosition.y
            ptr[2] = spriteSize.x
            ptr[3] = spriteSize.y

            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            // Triangle strip: 4 vertices, 2 triangles
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        // M5: FPS measurement — called on MTKView draw thread (not main thread).
        // Uses CACurrentMediaTime() which is monotonic and suitable for frame timing.
        frameCount += 1
        let now = CACurrentMediaTime()
        let elapsed = now - lastReportTime
        if elapsed >= fpsReportInterval {
            measuredFPS = Double(frameCount) / elapsed
            let budgetMs = elapsed / Double(max(1, frameCount)) * 1000.0
            print(String(format: "[Metal][FPS] %.0f fps (%.2f ms/frame)", measuredFPS, budgetMs))
            frameCount = 0
            lastReportTime = now
        }
    }
}
