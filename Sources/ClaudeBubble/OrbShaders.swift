/// Metal port of the shaders in the design's orbParticles.js. Compiled at runtime.
enum OrbShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 c1, c2, c3, halo;
    float4 a;   // phase, scale, glow, ring
    float4 b;   // glitch, wave, bright, pointSize
    float4 c;   // resX, resY, shiftX, unused
    float4 d;   // pointer offset x, y (radii, ≤ 1), attention, unused
};

struct QuadOut { float4 position [[position]]; };

vertex QuadOut quadVertex(uint vid [[vertex_id]]) {
    const float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    QuadOut o; o.position = float4(p[vid], 0, 1); return o;
}

fragment float4 quadFragment(QuadOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 res = u.c.xy;
    float2 frag = float2(in.position.x, res.y - in.position.y);
    // The whole orb drifts a little toward the pointer (matched in the particle pass).
    float2 uv = (frag - .5 * res) / res.y - float2(u.c.z, 0) - u.d.xy * (.3 * .07) * u.d.z;
    float ph = u.a.x, sc = u.a.y, glowv = u.a.z, ringv = u.a.w, glitch = u.b.x;
    float3 C1 = u.c1.xyz, C2 = u.c2.xyz, C3 = u.c3.xyz, H = u.halo.xyz;

    float R = .3 * sc; float r = length(uv); float a = atan2(uv.y, uv.x);
    float k = .5 + .5 * sin(a * 1. + ph * .9); float k2 = .5 + .5 * sin(a * 2. - ph * .6 + 1.3);
    float3 rc = mix(mix(C1, C2, k), C3, k2 * .6);
    float w = .016 + .01 * sin(a * 3. + ph);
    float gap = step(.7, fract(sin(floor(a * 6. + ph * 4.) * 57.3) * 913.1));
    w *= 1. - glitch * gap * .7;
    float d1 = (r - R * 1.02) / w; float ring = exp(-d1 * d1);
    float d2 = (r - R * 1.05) / (w * 2.6); float fuzz = exp(-d2 * d2) * .45;
    // Attention: a light follows the pointer over the sphere. Off-centre effects scale with how far out it is,
    // so passing over the middle is continuous.
    float2 po = u.d.xy; float att = u.d.z;
    float plen = min(length(po), 1.);
    float pa = plen > 1e-4 ? atan2(po.y, po.x) : 0.;   // atan2(0, 0) is NaN on the GPU and would blank the layer
    float hlBase = ph * .8 + 1.2;
    float2 hv = mix(float2(cos(hlBase), sin(hlBase)), float2(cos(pa), sin(pa)), att * plen);
    float hl = pow(.5 + .5 * cos(a - atan2(hv.y, hv.x)), 5.);
    float3 col = rc * (ring * (.55 + 1.6 * hl) + fuzz * (.4 + hl)) * ringv;
    col += float3(1.) * ring * hl * hl * .6 * ringv;
    // The rim and halo brighten on the side the light is on.
    float toward = pow(.5 + .5 * cos(a - pa), 3.) * att * plen;
    col *= 1. + .9 * toward;
    // A soft bloom where the light sits on the sphere's face (the middle when the pointer is centred).
    float2 spot = po * R * .85;
    float sd = length(uv - spot);
    col += mix(C2, C3, .5) * att * .4 * exp(-sd * sd / (R * R * .1)) * (1. - smoothstep(R * .85, R * 1.05, r));
    float o = max(r - R, 0.);
    col += H * glowv * (1. + 1.6 * toward) * (exp(-o * 7.) * .55 + exp(-o * 22.) * .5) * smoothstep(R * .7, R * 1.02, r);
    col += H * glowv * .12 * (1. - smoothstep(0., R, r));
    col *= 1. - smoothstep(.36, .5, r);
    col = 1. - exp(-col * 1.4);
    return float4(col, max(col.r, max(col.g, col.b)));
}

struct PointOut {
    float4 position [[position]];
    float size [[point_size]];
    float3 color;
};

float3x3 ry(float a) { float c = cos(a), s = sin(a); return float3x3(float3(c, 0, -s), float3(0, 1, 0), float3(s, 0, c)); }
float3x3 rx(float a) { float c = cos(a), s = sin(a); return float3x3(float3(1, 0, 0), float3(0, c, s), float3(0, -s, c)); }

vertex PointOut pointVertex(uint vid [[vertex_id]],
                            constant Uniforms& u [[buffer(0)]],
                            const device packed_float3* pts [[buffer(1)]]) {
    float3 pos = float3(pts[vid]);
    float ph = u.a.x, sc = u.a.y, glitch = u.b.x, wave = u.b.y, bright = u.b.z, pt = u.b.w;
    float3 C1 = u.c1.xyz, C2 = u.c2.xyz, C3 = u.c3.xyz;

    float3 p = pos;
    float tw = wave * .9 * sin(p.y * 3.2 + ph * 1.3);
    p = ry(ph * .35 + tw) * p;
    float dd = dot(p, normalize(float3(.3, -.2, .9))) - .55;
    float wv = sin(dot(p, float3(.55, .8, .25)) * 7. - ph * 2.6) * exp(-dd * dd * 5.);
    p *= 1. + wave * .07 * wv;
    float gh = fract(sin(dot(pos + floor(ph * 9.), float3(12.9898, 78.233, 37.719))) * 43758.5453);
    float band = step(.82, fract(sin(floor((pos.y + ph * .3) * 9.) * 91.7) * 437.5));
    p *= 1. + glitch * (gh * .1 + band * .12);
    p.x += glitch * band * .08 * sign(gh - .5);
    p = rx(.35) * p;
    // Attention: the sphere tilts toward the pointer (more the further off-centre it is).
    float2 po = u.d.xy; float att = u.d.z;
    p = ry(po.x * .45 * att) * rx(-po.y * .45 * att) * p;
    // ...and a light sits on its surface where the pointer is; dots near it brighten.
    float2 lp = po / max(1., length(po));
    float3 L = float3(lp, sqrt(max(1. - dot(lp, lp), 0.)));
    float dl = distance(normalize(p), L);              // 0 at the cursor's spot on the sphere, up to 2 opposite
    float near = exp(-dl * dl * 3.);
    // Pull: dots near the cursor lift off the surface toward it (the front bulges out when it's centred)...
    p += (L * 1.45 - p) * att * .4 * near;
    // ...and rings ripple out through the dots from that spot.
    p *= 1. + att * .075 * sin(dl * 16. - ph * 7.) * exp(-dl * 2.2);
    float lit = pow(max(dot(normalize(p), L), 0.), 6.) * att;
    float R = .6 * sc;
    float persp = 1. / (1. - p.z * .18);

    PointOut o;
    float2 drift = po * (R * .07) * att * 2.;          // clip space is 2× the quad's uv units
    o.position = float4(p.x * R * persp + u.c.z * 2. + drift.x, p.y * R * persp + drift.y, 0, 1);
    float limb = 1. - abs(p.z);
    float front = step(0., p.z);
    float3 c = mix(C2, C1, .5 + .5 * p.y);
    c = mix(c, C3, clamp(wv * wave, 0., 1.) * front);
    float b = (.12 + pow(limb, 4.) * 1.1 + max(wv, 0.) * wave * .9 * front) * mix(.35, 1., front);
    b *= 1. + 2.2 * lit;
    c = mix(c, C3, lit * .5);
    o.color = c * b * bright;
    o.size = pt * (1. + p.z * .5);
    return o;
}

fragment float4 pointFragment(PointOut in [[stage_in]], float2 pc [[point_coord]]) {
    float d = length(pc - .5);
    float a = 1. - smoothstep(.15, .5, d);
    float3 c = in.color * a;
    return float4(c, max(c.r, max(c.g, c.b)));
}
"""#
}

/// Must match `Uniforms` in OrbShaders.source.
struct OrbUniforms {
    var c1: SIMD4<Float>
    var c2: SIMD4<Float>
    var c3: SIMD4<Float>
    var halo: SIMD4<Float>
    var a: SIMD4<Float>
    var b: SIMD4<Float>
    var c: SIMD4<Float>
    var d: SIMD4<Float>
}
