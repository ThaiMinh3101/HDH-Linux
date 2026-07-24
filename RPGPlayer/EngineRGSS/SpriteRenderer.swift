// RPGPlayer/EngineRGSS/SpriteRenderer.swift
//
// MetalKit-based renderer for RGSS sprites.
// M1b: renders a single sprite texture full-screen as proof-of-concept.
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

        if let texture = currentTexture {
            encoder.setFragmentTexture(texture, index: 0)
            // Full-screen triangle strip: 4 vertices, 2 triangles
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
