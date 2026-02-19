#include <metal_stdlib>
using namespace metal;

struct ParticleVertex {
    float2 position;
    float  pointSize;
    float4 color;
};

struct VertexOut {
    float4 position [[position]];
    float  pointSize [[point_size]];
    float4 color;
};

struct Uniforms {
    float aspectRatio;
};

vertex VertexOut particleVertex(const device ParticleVertex *vertices [[buffer(0)]],
                                const device Uniforms &uniforms [[buffer(1)]],
                                uint vid [[vertex_id]]) {
    ParticleVertex v = vertices[vid];
    VertexOut out;
    out.position = float4(v.position.x / uniforms.aspectRatio, v.position.y, 0.0, 1.0);
    out.pointSize = v.pointSize;
    out.color = v.color;
    return out;
}

fragment float4 particleFragment(VertexOut in [[stage_in]],
                                 float2 pointCoord [[point_coord]]) {
    float dist = length(pointCoord - float2(0.5));
    float alpha = saturate(1.0 - dist * 2.0);
    alpha *= alpha;
    return float4(in.color.rgb, in.color.a * alpha);
}
