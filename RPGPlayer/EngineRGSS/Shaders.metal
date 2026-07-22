// RPGPlayer/EngineRGSS/Shaders.metal
//
// Metal shaders for RGSS sprite rendering — M1b: single full-screen quad.
//
// Pipeline: sprite_vertex → sprite_fragment
// Draw call: drawPrimitives(.triangleStrip, vertexStart: 0, vertexCount: 4)

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Vertex output
// ---------------------------------------------------------------------------
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// ---------------------------------------------------------------------------
// sprite_vertex
// Generates a full-screen quad from vertex IDs 0–3 (triangle strip).
// NDC range: [-1, 1] in X and Y. Texture UV: [0, 1] with Y-down convention
// matching Metal's top-left origin when using MTKView.
// ---------------------------------------------------------------------------
vertex VertexOut sprite_vertex(uint vid [[vertex_id]])
{
    // Vertex positions in Normalized Device Coordinates (Y-up, Metal convention)
    const float2 positions[4] = {
        float2(-1.0, -1.0),   // 0: bottom-left
        float2( 1.0, -1.0),   // 1: bottom-right
        float2(-1.0,  1.0),   // 2: top-left
        float2( 1.0,  1.0),   // 3: top-right
    };

    // UV coordinates (Y-down: v=0 at top, v=1 at bottom)
    // With MTKView's top-left origin this renders textures upright.
    const float2 uvs[4] = {
        float2(0.0, 1.0),   // 0: bottom-left  → UV bottom-left
        float2(1.0, 1.0),   // 1: bottom-right → UV bottom-right
        float2(0.0, 0.0),   // 2: top-left     → UV top-left
        float2(1.0, 0.0),   // 3: top-right    → UV top-right
    };

    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
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
