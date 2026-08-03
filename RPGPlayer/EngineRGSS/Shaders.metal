// RPGPlayer/EngineRGSS/Shaders.metal
//
// Metal shaders for RGSS sprite rendering.
// M1b: single full-screen quad (position=(0,0), size=(2,2) in NDC).
// M6.2: sprite can be drawn at an arbitrary (x, y) position with a given size
//       via the SpriteUniforms buffer — enables Game_Player movement rendering.
//
// Pipeline: sprite_vertex → sprite_fragment
// Draw call: drawPrimitives(.triangleStrip, vertexStart: 0, vertexCount: 4)

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Per-draw uniforms (set from Swift each frame)
// ---------------------------------------------------------------------------
struct SpriteUniforms {
    // Center of the sprite in Normalized Device Coordinates (NDC).
    // NDC range: [-1, 1] in X and Y. (0,0) = screen center.
    float2 position;
    // Size of the sprite in NDC. (2,2) = full screen.
    float2 size;
};

// ---------------------------------------------------------------------------
// Vertex output
// ---------------------------------------------------------------------------
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// ---------------------------------------------------------------------------
// sprite_vertex
// Generates a quad from vertex IDs 0–3 (triangle strip), centered at
// `u.position` with half-extents `u.size / 2`. Texture UV: [0, 1] with Y-down
// convention matching Metal's top-left origin when using MTKView.
// ---------------------------------------------------------------------------
vertex VertexOut sprite_vertex(uint vid [[vertex_id]],
                               constant SpriteUniforms &u [[buffer(0)]])
{
    // Quad corners relative to center (NDC, Y-up Metal convention)
    const float2 corners[4] = {
        float2(-0.5, -0.5),   // 0: bottom-left
        float2( 0.5, -0.5),   // 1: bottom-right
        float2(-0.5,  0.5),   // 2: top-left
        float2( 0.5,  0.5),   // 3: top-right
    };

    // UV coordinates (Y-down: v=0 at top, v=1 at bottom)
    const float2 uvs[4] = {
        float2(0.0, 1.0),   // 0: bottom-left  → UV bottom-left
        float2(1.0, 1.0),   // 1: bottom-right → UV bottom-right
        float2(0.0, 0.0),   // 2: top-left     → UV top-left
        float2(1.0, 0.0),   // 3: top-right    → UV top-right
    };

    VertexOut out;
    out.position = float4(u.position + corners[vid] * u.size, 0.0, 1.0);
    out.texCoord = uvs[vid];
    return out;
}

// ---------------------------------------------------------------------------
// sprite_fragment
// Samples the sprite texture with linear filtering and clamp-to-edge addressing.
// Outputs pre-multiplied RGBA for alpha blending in the pipeline.
// ---------------------------------------------------------------------------
fragment float4 sprite_fragment(VertexOut       in  [[stage_in]],
                                texture2d<float> tex [[texture(0)]])
{
    constexpr sampler s(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );
    return tex.sample(s, in.texCoord);
}