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

    /// Load a texture by bundle resource name (e.g. `"test.png"`).
    /// Falls back to a procedural checkerboard if the file is not found in the bundle,
    /// which still proves the Metal draw pipeline is working.
    func loadTexture(named name: String) {
        let ext  = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension

        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .SRGB: false
        ]

        if let url = Bundle.main.url(
            forResource:    base,
            withExtension:  ext.isEmpty ? nil : ext
        ) {
            do {
                currentTexture = try textureLoader.newTexture(URL: url, options: options)
                print("[SpriteRenderer] ✅ Texture loaded from bundle: \(name)")
            } catch {
                print("[SpriteRenderer] ⚠️  Bundle load failed (\(error)) — using fallback")
                currentTexture = makeFallbackTexture()
            }
        } else {
            print("[SpriteRenderer] ℹ️  '\(name)' not found in bundle — rendering fallback checkerboard")
            currentTexture = makeFallbackTexture()
        }
    }

    /// Procedural 64×64 pixel checkerboard texture.
    /// Colour scheme: warm orange / dark teal — visually distinct from background.
    /// Proves the Metal pipeline works even with no PNG in the bundle.
    private func makeFallbackTexture() -> MTLTexture? {
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
        print("[SpriteRenderer] ✅ Fallback checkerboard texture ready (\(size)×\(size))")
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
