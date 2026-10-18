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
    float4 d;   // pointer offset x, y (radii, ≤ 1), attention, completion time (s; < 0 = not playing)
    float4 e;   // ring pop time (s; < 0 = off), spawn pull amount, pull angle (radians, y-up), unused
    float4 f;   // work motion from, to (design WORK modes), blend 0…1, bash settle 0…1
    float4 g;   // subagents (eased), fail age (s; < 0 = off), skill age (s; < 0 = off), unused
    float4 h;   // three tool-complete tick ages (s; < 0 = none), unused
    float4 i;   // three tick amplitudes, unused
    float4 j, k, l, m;   // colour fan: the c1, c2, c3 and halo it sweeps away from
    float4 n;   // colour fan progress 0…1 (< 0 = settled), unused
    float4 o;   // edge squash: right, top, left, bottom edges' distances from the centre, in orb radii (≥ 1 = clear)
};

float2 unsquish(float2 q, float4 ed, float R, float ph);   // below, with the particle pass's squish

// Colour ripple: new colours spread from the orb's centre outward as an expanding ring. `along` is the distance from
// the centre in orb radii (the rim is 1, the halo beyond); returns how much of the new colour shows, and the ring's
// bright crest.
float2 fanMix(float along, float p) {
    if (p < 0.) return float2(1., 0.);
    float front = p * 1.9;
    float m = 1. - smoothstep(front - .16, front, along);
    float crest = exp(-pow((along - front + .07) / .06, 2.)) * (1. - p);
    return float2(m, crest);
}

struct QuadOut { float4 position [[position]]; };

vertex QuadOut quadVertex(uint vid [[vertex_id]]) {
    const float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    QuadOut o; o.position = float4(p[vid], 0, 1); return o;
}

fragment float4 quadFragment(QuadOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 res = u.c.xy;
    float2 frag = float2(in.position.x, res.y - in.position.y);
    // The whole orb drifts a little toward the pointer (matched in the particle pass).
    // Squished against a screen edge (matched in the particle pass): look up where this pixel was before the squish.
    float2 clip = (frag - .5 * res) / res.y * 2.;
    float2 raw = unsquish(clip, u.o, .6 * u.a.y, u.a.x) * .5;
    float2 uv = raw - float2(u.c.z, 0) - u.d.xy * (.3 * .07) * u.d.z;
    float ph = u.a.x, sc = u.a.y, glowv = u.a.z, ringv = u.a.w, glitch = u.b.x;
    float3 C1 = u.c1.xyz, C2 = u.c2.xyz, C3 = u.c3.xyz, H = u.halo.xyz;
    float R = .3 * sc; float r = length(uv); float a = atan2(uv.y, uv.x);
    float2 fm = fanMix(r / max(R, 1e-4), u.n.x);
    C1 = mix(u.j.xyz, C1, fm.x); C2 = mix(u.k.xyz, C2, fm.x); C3 = mix(u.l.xyz, C3, fm.x); H = mix(u.m.xyz, H, fm.x);
    float k = .5 + .5 * sin(a * 1. + ph * .9); float k2 = .5 + .5 * sin(a * 2. - ph * .6 + 1.3);
    float3 rc = mix(mix(C1, C2, k), C3, k2 * .6);
    float w = .016 + .01 * sin(a * 3. + ph);
    float gap = step(.7, fract(sin(floor(a * 6. + ph * 4.) * 57.3) * 913.1));
    w *= 1. - glitch * gap * .7;
    // Spawn pull (design: Pip Sounds): the ring bulges toward the new pip's slot like taffy.
    float bul = u.e.y * .3 * pow(max(cos(a - u.e.z), 0.), 18.);
    float d1 = (r - R * (1.02 + bul)) / w; float ring = exp(-d1 * d1);
    float d2 = (r - R * (1.05 + bul)) / (w * 2.6); float fuzz = exp(-d2 * d2) * .45;
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
    col += rc * ring * abs(bul) * 5. * ringv;
    col += mix(rc, float3(1.), .4) * (ring * 1.4 + fuzz) * fm.y * ringv;   // the ripple lighting the rim as it passes
    col += mix(H, float3(1.), .3) * fm.y * .35 * smoothstep(R * .95, R * 1.15, r);   // and carrying on through the halo
    // The rim and halo brighten on the side the light is on.
    float toward = pow(.5 + .5 * cos(a - pa), 2.) * att * plen;
    col *= 1. + .9 * toward;
    // A soft bloom where the light sits on the sphere's face (the middle when the pointer is centred).
    float2 spot = po * R * .85;
    float sd = length(uv - spot);
    // Lit in the orb's own colours (its halo and deep secondary), no added white, so it glows like the halo does.
    col += (H * 1.8 + C2 * .55) * att * .75 * exp(-sd * sd / (R * R * .24)) * (1. - smoothstep(R * .8, R * 1.05, r));
    float o = max(r - R, 0.);
    col += H * glowv * (1. + 1.6 * toward) * (exp(-o * 7.) * .55 + exp(-o * 22.) * .5) * smoothstep(R * .7, R * 1.02, r);
    // Completed moment (design: Completed Moment): rim gathers, two chromatic rings ease out, a brief white flash.
    float dT = u.d.w;
    if (dT >= 0.) {
        float g = smoothstep(0., .38, dT) * (1. - smoothstep(.38, .46, dT));
        col += rc * ring * g * 1.4;
        float l1 = max(dT - .42, 0.) / 1.1, l2 = max(dT - .6, 0.) / 1.5;
        float e1 = 1. - pow(1. - clamp(l1, 0., 1.), 3.), e2 = 1. - pow(1. - clamp(l2, 0., 1.), 3.);
        float3 off = float3(.007, 0., -.007);   // per-channel radius offset = chromatic fringe
        float3 d1 = (float3(r) - (R * (1.02 + e1 * .5) + off * e1)) / (.006 + .012 * e1);
        float3 d2 = (float3(r) - (R * (1.02 + e2 * .36) + off * e2)) / (.004 + .01 * e2);
        float a1 = step(.42, dT) * pow(1. - clamp(l1, 0., 1.), 1.6);
        float a2 = step(.6, dT) * pow(1. - clamp(l2, 0., 1.), 1.6) * .6;
        col += exp(-d1 * d1) * a1 * 1.3 + exp(-d2 * d2) * a2;
        float fl = step(.42, dT) * exp(-(dT - .42) * 3.);
        col += float3(1., .97, .95) * fl * .35 * (1. - smoothstep(0., R * 1.3, r));
    }
    // Ring pop (one session finished while others carry on): a single chromatic ring easing out.
    float pT = u.e.x;
    if (pT >= 0.) {
        float lp1 = clamp(pT / 1.1, 0., 1.);
        float ep = 1. - pow(1. - lp1, 3.);
        float3 off = float3(.007, 0., -.007);
        float3 dp = (float3(r) - (R * (1.02 + ep * .5) + off * ep)) / (.006 + .012 * ep);
        col += exp(-dp * dp) * pow(1. - lp1, 1.6) * 1.1;
    }
    col += H * glowv * .12 * (1. - smoothstep(0., R, r));
    col *= 1. - smoothstep(.36, .5, r);
    // Squished, the glow can reach the window's sides: fade it out before them, never a hard edge.
    col *= (1. - smoothstep(.8, .99, abs(clip.x))) * (1. - smoothstep(.8, .99, abs(clip.y)));
    col = 1. - exp(-col * 1.4);
    return float4(col, max(col.r, max(col.g, col.b)));
}

struct PointOut {
    float4 position [[position]];
    float size [[point_size]];
    float3 color;
};

float hs(float3 v) { return fract(sin(dot(v, float3(12.9898, 78.233, 37.719))) * 43758.5453); }

// smoothstep that also runs downhill (edge0 > edge1), as the design's GLSL relies on.
float ss(float a, float b, float x) { float t = clamp((x - a) / (b - a), 0., 1.); return t * t * (3. - 2. * t); }
float angTo(float3 q, float3 d) { return acos(clamp(dot(q, normalize(d)), -1., 1.)); }
// A smooth minimum: the lesser of a and b, rounded over k.
float smin(float a, float b, float k) { float h = clamp(.5 + .5 * (b - a) / k, 0., 1.); return mix(b, a, h) - k * h * (1. - h); }

// Edge squash (EdgeSquash): the orb squeezed against a screen edge like a soft ball of liquid. Per edge, in clip units
// from the centre (R: the orb's radius there), with `e` that edge's distance in radii (1 or more: clear; the spring's
// rebound reads a little past 1). The orb compresses as a whole between the wall and its far side, so it stays round
// and smooth; pushed further it stays on the wall, thinner, oozing out along it (a little fuller where it touches).
// It never spreads past the window (±1). `a` runs toward the wall, `b` along it.
struct Wall { float c; float g0; float bulge; float sag; float most; bool on; };

// A partial squish: the orb is squeezed only halfway to the wall, so the rest of it reaches past and lies flat on it.
float reach(float e) { return e < 1. ? mix(e, 1., .5) : e; }

// `ph`: the orb's phase, for a slow sway; `sags`: a side wall, where the drop slumps downward.
Wall wall(float e, float R, float ph, bool sags) {
    Wall w; w.on = abs(e - 1.) > 1e-4;
    w.c = clamp((reach(e) + 1.) * .5, .6, 1.15);   // how much of its width is left
    float sb = 1. + .55 * (1. / w.c - 1.);   // keeps roughly its area: spread along the wall
    w.most = .93 / (R * 1.15);               // the window's room along the wall
    if (sb > 1.) sb = 1. + smin(sb - 1., w.most - 1., .2);
    float squeezed = max(1. - w.c, 0.);
    w.g0 = sb;
    w.bulge = squeezed * .6 * (1. + .12 * sin(ph * 1.7));   // pressed flat and wide where it touches, swaying
    w.sag = sags ? squeezed * .35 * R : 0.;
    return w;
}

// How wide the drop is at `a` (toward the wall), and how far it slumps there.
float2 wallSpread(Wall w, float a, float R) {
    float t = ss(-1., 1., a / R);
    float g = w.g0 * (1. + w.bulge * (t * t * 2. - .6));
    g = min(g, 1. + smin(g - 1., w.most - 1., .2));
    return float2(g, w.sag * t);
}

float2 wallSquish(float a, float b, float e, float R, float ph, bool sags) {
    Wall w = wall(e, R, ph, sags);
    if (!w.on) return float2(a, b);
    float2 gs = wallSpread(w, a, R);
    // Squeezed toward the wall (or the rebound's stretch), then what reaches past it lies flat on it, the corners of
    // the flat rounded. (The per-pixel pass skips the flattening: past the wall is off screen, so the screen's edge
    // makes the same flat face.)
    float a2 = e < 1. ? reach(e) * R - (R - a) * w.c : a * w.c;
    if (e < 1.) a2 = smin(a2, e * R, .1 * R);
    return float2(a2, b * gs.x - gs.y);
}

float2 wallUnsquish(float a2, float b2, float e, float R, float ph, bool sags) {
    Wall w = wall(e, R, ph, sags);
    if (!w.on) return float2(a2, b2);
    float a = e < 1. ? R - (reach(e) * R - a2) / w.c : a2 / w.c;
    float2 gs = wallSpread(w, a, R);
    return float2(a, (b2 + gs.y) / gs.x);
}

// `ed`: right, top, left, bottom edges' distances. Left and bottom are the right and top mirrored.
float2 squish(float2 p, float4 ed, float R, float ph) {
    // Side walls: the drop slumps down (y up, so its along-wall offset is subtracted). Top and bottom: no slump.
    if (ed.x < ed.z) { float2 r = wallSquish(p.x, p.y, ed.x, R, ph, true); p = r; }
    else { float2 r = wallSquish(-p.x, p.y, ed.z, R, ph, true); p = float2(-r.x, r.y); }
    if (ed.y < ed.w) { float2 r = wallSquish(p.y, p.x, ed.y, R, ph, false); p = float2(r.y, r.x); }
    else { float2 r = wallSquish(-p.y, p.x, ed.w, R, ph, false); p = float2(r.y, -r.x); }
    return p;
}

// Where a squished point came from, so the body, rim and glow drawn per pixel squish with the dots.
float2 unsquish(float2 q, float4 ed, float R, float ph) {
    float2 p = q;
    if (ed.y < ed.w) { float2 r = wallUnsquish(p.y, p.x, ed.y, R, ph, false); p = float2(r.y, r.x); }
    else { float2 r = wallUnsquish(-p.y, p.x, ed.w, R, ph, false); p = float2(r.y, -r.x); }
    if (ed.x < ed.z) { float2 r = wallUnsquish(p.x, p.y, ed.x, R, ph, true); p = r; }
    else { float2 r = wallUnsquish(-p.x, p.y, ed.z, R, ph, true); p = float2(-r.x, r.y); }
    return p;
}
float rpl(float3 q, float3 s, float pa) { float an = angTo(q, s); return pow(max(sin(an * 7. - pa * 3.5), 0.), 3.) * 1.7 * exp(-an * .45); }
float bn(float3 b, float pa) {
    return sin(b.x + pa * 1.1) * sin(b.y * 1.2 - pa * .8) * sin(b.z * .9 + pa * .95)
         + .5 * sin(b.x * 2.1 - pa * 1.5 + b.z * 1.4) * sin(b.y * 1.9 + pa);
}

// Work motions (design: Orb States, wkm in orbParticles.js). Returns (wave, amplitude); mode 0 keeps the rolling wave.
float2 wkm(float m, float3 q, float pa, float wv0, float settle) {
    if (m < .5) return float2(wv0, .07);
    float wv, wa;
    if (m < 2.5) {                       // edit · Emit: rings push outward from the front point
        float an = angTo(q, float3(.3, .35, .89));
        wv = pow(max(sin(an * 7. - pa * 3.5), 0.), 3.) * 1.7 * exp(-an * .45); wa = .08;
    } else if (m < 9.5) {                // web · Drifting ripple: the source wanders around the face
        wv = rpl(q, float3(sin(pa * .3) * .8, cos(pa * .23) * .5, .7), pa); wa = .08;
    } else if (m < 12.5) {               // search · Radar: a meridian sweeps with a fading wake
        float h = fract(pa * (1.5 / 6.2832) - atan2(q.z, q.x) / 6.2832);   // 300 whole turns per phase wrap
        wv = exp(-h * 7.) * 1.6 + exp(-pow(h / .015, 2.)) * .6 - .05; wa = .05;
    } else if (m < 17.5) {               // read · Converge: rings flow inward to the front point
        float an = angTo(q, float3(.3, .35, .89));
        wv = pow(max(sin(an * 7. + pa * 3.), 0.), 3.) * 1.7 * ss(2.6, .15, an); wa = -.05;
    } else if (m < 23.5) {               // mcp · Link: bulges toward one side, pulses travel into it
        float an = angTo(q, float3(0., .96, .28));
        wv = ss(.75, 0., an) * 1.1 + pow(max(sin(an * 9. + pa * 4.), 0.), 4.) * ss(1.6, .25, an) * 1.5; wa = .13;
    } else if (m < 24.5) {               // compacting · Fold: bands slide to the equator and sink
        wv = pow(.5 + .5 * sin(abs(q.y) * 8. + pa * 2.3), 3.) * 1.15 - .15; wa = -.075;
    } else if (m < 25.5) {               // waiting · Still: the base nearly stops; subagent ripples carry it
        wv = .35 * sin(dot(q, normalize(float3(.55, .8, .25))) * 2. - pa * .5); wa = .03;
    } else {                             // bash · Boil → simmer, by how long the command has run
        float bo = bn(q * 2.6, pa * .9) * 1.5;
        float3 b = q * 3.; b.y -= pa * .7;
        float si = pow(max(bn(b, pa * .6), 0.), 1.5) * 1.6 - .1;
        wv = mix(bo, si, settle) * (1. + .25 * (1. - settle)); wa = mix(.1, .07, settle);
    }
    return float2(wv, wa);
}

float3x3 ry(float a) { float c = cos(a), s = sin(a); return float3x3(float3(c, 0, -s), float3(0, 1, 0), float3(s, 0, c)); }
float3x3 rx(float a) { float c = cos(a), s = sin(a); return float3x3(float3(1, 0, 0), float3(0, c, s), float3(0, -s, c)); }

vertex PointOut pointVertex(uint vid [[vertex_id]],
                            constant Uniforms& u [[buffer(0)]],
                            const device packed_float3* pts [[buffer(1)]]) {
    float3 pos = float3(pts[vid]);
    float ph = u.a.x, sc = u.a.y, glitch = u.b.x, wave = u.b.y, bright = u.b.z, pt = u.b.w;
    float3 C1 = u.c1.xyz, C2 = u.c2.xyz, C3 = u.c3.xyz;

    float3 p = pos;
    float workA = u.f.x, workB = u.f.y, workM = u.f.z;
    // The twist belongs to the rolling wave only, so it blends out with it.
    float tw = wave * .9 * sin(p.y * 3.2 + ph * 1.3) * mix(step(workA, .5), step(workB, .5), workM);
    p = ry(ph * .35 + tw) * p;
    float dd = dot(p, normalize(float3(.3, -.2, .9))) - .55;
    float wv0 = sin(dot(p, float3(.55, .8, .25)) * 7. - ph * 2.6) * exp(-dd * dd * 5.);
    float3 q = normalize(p);
    float2 wk = wkm(workA, q, ph, wv0, u.f.w);
    if (workM > .999) wk = wkm(workB, q, ph, wv0, u.f.w);
    else if (workM > .001) wk = mix(wk, wkm(workB, q, ph, wv0, u.f.w), workM);
    float wv = wk.x * (1. - clamp(min(u.g.x, 3.) * .18, 0., .65));   // subagents duck the base motion
    // Layers (design: Orb States): subagent interference, tool-complete ticks, a failed tool's dent, a skill's sweep.
    float ly = 0.;
    float fan = angTo(q, float3(.3, .35, .89));
    for (int k = 0; k < 6; k++) {
        float fk = float(k), wg = clamp(u.g.x - fk, 0., 1.);
        if (wg > 0.) {
            float3 sd = float3(sin(fk * 2.4 + ph * (.06 + fk * .01)) * .85, cos(fk * 1.7 + .6) * .6, .55);
            float an = angTo(q, sd);
            ly += pow(max(sin(an * 5. - ph * (1.21 + fk * .09) - fk * 2.86), 0.), 2.) * .75 * exp(-an * .6) * wg / (1. + .4 * fk);
        }
    }
    for (int k = 0; k < 3; k++) {
        float ag = u.h[k];
        if (ag >= 0. && ag < .8) ly += exp(-pow((fan - ag * 2.8) / .1, 2.)) * 1.6 * u.i[k] * exp(-ag * 4.);
    }
    float fa = u.g.y;
    if (fa >= 0. && fa < 1.2) { float dn = distance(q, normalize(float3(-.45, .25, .86))); ly -= exp(-dn * dn / .04) * 2.6 * exp(-fa * 3.5); }
    float sk = u.g.z;
    if (sk >= 0. && sk < 1.6) {
        float sa = ss(0., 1.4, sk) * 3.1416;
        float3 sn = normalize(float3(cos(sa), .35, sin(sa)));
        ly += exp(-pow(dot(q, sn) / .1, 2.)) * 1.3 * ss(0., .25, sk) * (1. - ss(1., 1.6, sk));
    }
    p *= 1. + wave * (wk.y * wv + .1 * ly);
    wv += ly;
    float gh = fract(sin(dot(pos + floor(ph * 9.), float3(12.9898, 78.233, 37.719))) * 43758.5453);
    float band = step(.82, fract(sin(floor((pos.y + ph * .3) * 9.) * 91.7) * 437.5));
    p *= 1. + glitch * (gh * .1 + band * .12);
    p.x += glitch * band * .08 * sign(gh - .5);
    // Completed moment: dots gather in, then spring out in a wave travelling bottom to top.
    float dT = u.d.w, hasD = step(0., dT);
    float gather = hasD * smoothstep(0., .38, dT) * (1. - smoothstep(.38, .46, dT));
    float since = dT - .42 - (pos.y + 1.) * .09;      // each dot releases a little later the higher it sits
    float rel = max(since, 0.), released = hasD * step(0., since);
    float spring = released * exp(-rel * 4.5) * sin(rel * 13. + .2);
    float flash = released * exp(-rel * 3.2);
    p *= 1. - .14 * gather;
    p *= 1. + spring * (.22 + .3 * hs(pos));
    p = rx(.35) * p;
    // Attention: the sphere tilts toward the pointer (more the further off-centre it is).
    float2 po = u.d.xy; float att = u.d.z;
    p = ry(po.x * .45 * att) * rx(-po.y * .45 * att) * p;
    // ...and a light sits on its surface where the pointer is; dots near it brighten.
    float2 lp = po / max(1., length(po));
    float3 L = float3(lp, sqrt(max(1. - dot(lp, lp), 0.)));
    float dl = distance(normalize(p), L);              // 0 at the cursor's spot on the sphere, up to 2 opposite
    // Swell: a broad, soft dome rises toward the cursor. Dots move outward along their own normal
    // (not toward one point), so the surface bulges smoothly instead of pinching into a tip.
    float near = exp(-dl * dl * 1.1);
    p *= 1. + att * .2 * near;
    // Slow, wide waves roll out through the dots from that spot.
    p *= 1. + att * .035 * sin(dl * 8. - ph * 4.) * exp(-dl * 1.4);
    float lit = pow(max(dot(normalize(p), L), 0.), 3.) * att;
    float R = .6 * sc;
    float persp = 1. / (1. - p.z * .18);

    PointOut o;
    float2 drift = po * (R * .07) * att * 2.;          // clip space is 2× the quad's uv units
    // Spawn pull: rim dots facing the new pip's slot stretch toward it (up to a third of the radius) and pinch in.
    float2 sp = float2(p.x, p.y) * R * persp;
    float pullAmt = u.e.y;
    float2 pdir = float2(cos(u.e.z), sin(u.e.z));
    float pal = dot(normalize(sp + float2(1e-5)), pdir);
    float pk = pow(max(pal, 0.), 14.) * smoothstep(.25 * R, .85 * R, length(sp)) * (.55 + .45 * step(0., p.z));
    sp += pdir * pk * pullAmt * R * .32;
    sp -= (sp - pdir * dot(sp, pdir)) * pk * max(pullAmt, 0.) * .45;
    // The pointer's drift and the shake move the whole orb: before the squash, so its flat face stays on the edge.
    sp += float2(u.c.z * 2. + drift.x, drift.y);
    sp = squish(sp, u.o, R, ph);
    o.position = float4(sp, 0, 1);
    float limb = 1. - abs(p.z);
    float front = step(0., p.z);
    float2 fmp = fanMix(length(p.xy), u.n.x);
    C1 = mix(u.j.xyz, C1, fmp.x); C2 = mix(u.k.xyz, C2, fmp.x); C3 = mix(u.l.xyz, C3, fmp.x);
    float3 c = mix(C2, C1, .5 + .5 * p.y);
    c = mix(c, C3, clamp(wv * wave, 0., 1.) * front);
    float b = (.12 + pow(limb, 4.) * 1.1 + max(wv, 0.) * wave * .9 * front) * mix(.35, 1., front);
    b *= 1. + 1.7 * lit;   // brighter in their own colour
    // Completed moment: an iridescent wash rides the release, then a specular sheen glides diagonally across.
    float3 irid = .62 + .38 * cos(6.2832 * (float3(0., .33, .67) + pos.y * .35 + pos.x * .2 + rel * .6));
    c = mix(c, irid, flash * .85);
    b += flash * 1.3 + gather * .5 * limb;
    float sweep = smoothstep(0., 1., (dT - .95) / 1.3);
    float band2 = dot(p.xy, float2(.83, .55)) - mix(-1.3, 1.3, sweep);
    float sheen = hasD * step(.95, dT) * step(dT, 2.25) * exp(-band2 * band2 * 22.) * front;
    c = mix(c, float3(1.), sheen * .7);
    b += sheen * .9;
    // Ring pop: just the sheen, sooner.
    float pT = u.e.x;
    float psweep = smoothstep(0., 1., (pT - .15) / 1.1);
    float pband = dot(p.xy, float2(.83, .55)) - mix(-1.3, 1.3, psweep);
    float psheen = step(.15, pT) * step(pT, 1.25) * exp(-pband * pband * 22.) * front;
    c = mix(c, float3(1.), psheen * .6);
    b += psheen * .8;
    b += pk * abs(pullAmt) * 1.3;
    b += fmp.y * .9 * front;   // the ripple's bright ring
    c = mix(c, float3(1.), pk * max(pullAmt, 0.) * .3);
    o.color = c * b * bright;
    o.size = pt * (1. + p.z * .5) * (1. + flash * .6);
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
    var e: SIMD4<Float>
    /// Defaults: the rolling wave, no layers playing.
    var f: SIMD4<Float> = [0, 0, 1, 0]
    var g: SIMD4<Float> = [0, -1, -1, 0]
    var h: SIMD4<Float> = [-1, -1, -1, 0]
    var i: SIMD4<Float> = .zero
    var j: SIMD4<Float> = .zero
    var k: SIMD4<Float> = .zero
    var l: SIMD4<Float> = .zero
    var m: SIMD4<Float> = .zero
    /// No colour fan by default.
    var n: SIMD4<Float> = [-1, 0, 0, 0]
    /// No edge close enough to squash by default.
    var o: SIMD4<Float> = SIMD4(repeating: 1)   // EdgeSquash.far
}
