#include <metal_stdlib>
using namespace metal;

// Geodesic-traced Schwarzschild black hole, after Eric Bruneton's
// "Real-time High-Quality Rendering of Non-Rotating Black Holes"
// (https://ebruneton.github.io/black_hole_shader/) and the
// blackhole_ghostty single-pass adaptation. Bruneton precomputes the
// geodesics into lookup textures; here each pixel's null geodesic is
// integrated numerically — the Binet-form photon acceleration
// a = -(3/2) h² x / r⁵ reproduces the exact Schwarzschild bending.
//
//   * shadow        — rays with impact parameter under b_crit = (3√3/2) r_s
//                     spiral into the horizon
//   * lensing       — escaped rays are projected back onto the desktop
//                     "sky" plane: the screenshot bends, magnifies and
//                     mirrors inside the Einstein ring
//   * photon ring   — rays winding near the r = 1.5 r_s photon sphere
//   * accretion disk— thin Keplerian disk the ray may cross several times;
//                     blackbody color from a Shakura–Sunyaev temperature
//                     profile, shifted and beamed by the relativistic
//                     factor g = √(1 − 1.5 r_s/r)/(1 − β·k̂)
//   * starfield     — lensed sky for when there is no screen capture
//
// Units: r_s (Schwarzschild radius) = 1.
//
// Cost model: only pixels within b < DISK_OUTER+3 of the hole pay the
// N_STEPS integration; everything else takes the analytic weak-field
// path (a handful of ALU ops + 3 texture samples), and pixels outside
// the warp window exit with a single sample.

// geodesic integration steps per pixel (only the near field pays this)
#define N_STEPS 48

// critical impact parameter of a Schwarzschild hole, in r_s: rays under
// this fall in; it is the apparent (shadow) radius seen from far away
#define B_CRIT 2.5980762

// Must match Renderer.Uniforms in Swift (same member order).
struct Uniforms {
    float  time;
    float  aspect;
    float2 center;        // hole position in UV space (0..1, y down)
    float  holeRadius;    // apparent shadow radius, in screen-height units
    float  hasCapture;    // 1 = desktop screenshot available
    // disk look (the preset, resolved on the CPU)
    float  diskTemp;      // hottest annulus temperature, Kelvin
    float  diskIncl;      // inclination, rad: 0 face-on, ~1.57 edge-on
    float  diskRoll;      // rotation of the system in the screen plane
    float  diskInner;     // inner edge, r_s
    float  diskOuter;     // outer edge, r_s
    float  diskOpacity;   // how much the near disk hides what's behind it
    float  dopplerMix;    // 0 = no relativistic asymmetry, 1 = full
    float  diskBeam;      // beaming exponent: intensity scales as g^N
    float  diskGain;      // disk emission brightness
    float  diskContrast;  // streak contrast: 0 smooth haze, higher filaments
    float  diskWind;      // spiral winding tightness of the streaks
    float  diskSpeed;     // streak pattern speed; negative reverses orbit
    float  exposure;      // tonemap exposure for the disk light
    float  starGain;      // lensed starfield brightness
    float  lensDepth;     // hole-to-sky-plane distance, r_s: bigger bends more
    float  warpReach;     // warp window falloff, in hole radii
};

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

// Fullscreen triangle — no vertex buffer needed.
vertex VOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    VOut o;
    o.pos = float4(p[vid], 0.0, 1.0);
    o.uv  = p[vid] * 0.5 + 0.5;
    o.uv.y = 1.0 - o.uv.y;   // texture origin is top-left
    return o;
}

// ------------------------------------------------------------------- noise --

// GLSL-style mod: always wraps into [0, y) even for negative x
static float glmod(float x, float y) { return x - y * floor(x / y); }

static float hash21(float2 p) {
    p = fract(p * float2(234.34, 435.345));
    p += dot(p, p + 34.23);
    return fract(p.x * p.y);
}

// value noise whose y lattice wraps every perY cells — used for the disk's
// angular dimension so the streaks tile seamlessly across the atan branch cut
static float vnoiseWrapY(float2 p, float perY) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float y0 = glmod(i.y, perY), y1 = glmod(i.y + 1.0, perY);
    return mix(mix(hash21(float2(i.x, y0)), hash21(float2(i.x + 1.0, y0)), f.x),
               mix(hash21(float2(i.x, y1)), hash21(float2(i.x + 1.0, y1)), f.x),
               f.y);
}

static float2 rot2(float2 v, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}

// blackbody color from temperature in Kelvin (Tanner Helland fit, normalized)
static float3 blackbody(float T) {
    float t = clamp(T, 1500.0, 40000.0) / 100.0;
    float r = t <= 66.0 ? 1.0
                        : clamp(1.292936 * pow(t - 60.0, -0.1332047), 0.0, 1.0);
    float g = t <= 66.0 ? clamp(0.3900816 * log(t) - 0.6318414, 0.0, 1.0)
                        : clamp(1.1298909 * pow(t - 60.0, -0.0755148), 0.0, 1.0);
    float b = t >= 66.0 ? 1.0
                        : (t <= 19.0 ? 0.0
                                     : clamp(0.5432068 * log(t - 10.0) - 1.1962540, 0.0, 1.0));
    return float3(r, g, b);
}

// sparse procedural starfield indexed by ray direction — because it is
// sampled with the *bent* ray, stars smear into arcs around the hole for free
static float3 stars(float3 d, float time) {
    float2 sph = float2(atan2(d.x, -d.z), asin(clamp(d.y, -1.0, 1.0)));
    float2 g   = sph * 40.0;
    float2 id  = floor(g);
    float  h   = hash21(id);
    if (h < 0.92) return float3(0.0);
    float2 f   = fract(g) - 0.5;
    float2 off = (float2(hash21(id + 17.3), hash21(id + 31.7)) - 0.5) * 0.7;
    float spark = smoothstep(0.10, 0.0, length(f - off));
    float tw    = 0.7 + 0.3 * sin(time * (0.5 + 2.0 * hash21(id + 5.1)) + 40.0 * h);
    float3 tint = mix(float3(1.0, 0.82, 0.60), float3(0.75, 0.85, 1.0), hash21(id + 2.9));
    return tint * spark * tw * ((h - 0.92) / 0.08);
}

// ------------------------------------------------------------------- image --

fragment float4 blackhole_fragment(VOut in [[stage_in]],
                                   texture2d<float> screen [[texture(0)]],
                                   constant Uniforms& u [[buffer(0)]])
{
    // mirrored repeat keeps lensed samples on-screen without edge smearing
    constexpr sampler smp(address::mirrored_repeat, filter::linear);

    float2 uv     = in.uv;
    float  aspect = u.aspect;
    float  t      = u.time;

    // disk extent sanitized: the inner edge stays outside the photon sphere
    // (1.5 r_s) where circular orbits stop making sense
    float rin  = max(u.diskInner, 1.6);
    float rout = max(u.diskOuter, rin + 0.5);
    float rh   = max(u.holeRadius, 1e-3);   // shadow radius in screen units

    // deep-space tint behind everything when there is no capture
    float3 space = float3(0.004, 0.005, 0.009) * (1.0 - u.hasCapture);

    // aspect-corrected frame centered on the hole (y in screen-height units)
    float2 p    = (uv - u.center) * float2(aspect, 1.0);
    float  plen = length(p);

    // distance-window: real lensing falls off as 1/b and would shimmer the
    // whole desktop as the hole drifts; fade it out warpReach hole radii away
    float window = exp(-pow(plen / (u.warpReach * rh), 2.0));

    // screen <-> world mapping: the shadow's true angular size is B_CRIT r_s
    // and we want it rh screen units, so 1 screen unit = W Schwarzschild radii
    float  W  = B_CRIT / rh;
    float2 pr = rot2(float2(p.x, -p.y), u.diskRoll) * W;
    float  b  = length(pr);            // the ray's impact parameter, in r_s

    float bmax = rout + 3.0;           // rays beyond this can't touch the disk
    float Z0   = max(14.0, rout + 5.0); // camera distance (shared with tracer)

    // outside the warp window nothing is visibly bent: one sample and out —
    // this is the path the vast majority of pixels take
    if (b >= bmax && window < 0.004) {
        return float4(screen.sample(smp, uv).rgb * u.hasCapture + space, 1.0);
    }

    // ================= far field: analytic weak deflection ==================
    // Finite-camera weak-field bend, fitted against the integrator so there
    // is no visible seam at the b = bmax handoff circle (sub-1% displacement
    // mismatch): disp = (2/b)(1.29u + 0.07)(L − 2.14u + 0.75), u = Z0/√(Z0²+b²).
    if (b >= bmax) {
        float uu   = Z0 * rsqrt(Z0 * Z0 + b * b);
        float defl = (2.0 / (W * W)) / max(plen, 1e-4)
                   * (1.29 * uu + 0.07) * max(u.lensDepth - 2.14 * uu + 0.75, 0.0)
                   * window;
        float2 dir = p / max(plen, 1e-5);
        float3 term = float3(0.0);
        // mild chromatic aberration: blue bends a touch more than red; faded
        // in away from the handoff circle (the geodesic side has none)
        float ab = 0.035 * smoothstep(1.0, 2.0, b / bmax);
        for (int i = 0; i < 3; i++) {
            float  k   = 1.0 + (float(i) - 1.0) * ab;
            float2 sp  = p - dir * defl * k;
            float2 suv = u.center + sp / float2(aspect, 1.0);
            term[i]    = screen.sample(smp, suv)[i];
        }
        term *= u.hasCapture;
        // same starfield as the geodesic region, lit through the weak-field
        // bend so stars don't pop at the boundary circle
        if (u.starGain > 0.001) {
            float3 d = normalize(float3(-(pr / b) * (2.0 / b), -1.0));
            term += stars(d, t) * u.starGain * window;
        }
        return float4(space + term, 1.0);
    }

    // ====================== near field: trace the geodesic ==================
    // Parallel rays from a distant camera at +z. The hole is at the origin,
    // r_s = 1. Integrate  x'' = -(3/2) h² x / r⁵  (exact Schwarzschild photon
    // bending; h = |x×v| is conserved, so it's computed once).
    //
    // NOTE: the entry plane (z = Z0) and exit conditions must stay exactly
    // as the far-field formula was fitted, or a circular displacement seam
    // appears at the b = bmax handoff. Truncating the trajectory earlier
    // (e.g. once it leaves the disk region) is NOT safe: Schwarzschild
    // bending has heavy tails and the deflection skipped outside even a
    // generous cutoff sphere projects to a visible jump on the sky plane.
    float3 x  = float3(pr, Z0);
    float3 v  = float3(0.0, 0.0, -1.0);
    float  h2 = dot(pr, pr);
    // Pure-lens presets have no disk light and no occlusion: skip the
    // crossing shading entirely, the loop then only bends the ray
    bool   hasDisk = (u.diskGain > 0.001) || (u.diskOpacity > 0.001);

    // disk plane: normal tilted diskIncl about the screen x-axis
    float  ci = cos(u.diskIncl), si = sin(u.diskIncl);
    float3 n  = float3(0.0, si, ci);
    float3 e2 = float3(0.0, ci, -si);   // in-plane axis completing (x̂, e2, n)
    float sdir = u.diskSpeed < 0.0 ? -1.0 : 1.0;
    float spd  = abs(u.diskSpeed);

    float3 emitc = float3(0.0);         // accumulated disk light (HDR)
    float  trans = 1.0;                 // transmittance toward the background
    bool   captured = false;
    float  sPrev = dot(x, n);
    float3 xPrev = x;

    for (int i = 0; i < N_STEPS; i++) {
        float r2 = dot(x, x);
        if (r2 < 1.0) { captured = true; break; }        // through the horizon
        if (x.z < -Z0 && v.z < 0.0) break;               // escaped out the back
        if (r2 > 4.0 * Z0 * Z0) break;                   // flung far sideways
        float r = sqrt(r2);
        // step scales with radius: fine near the photon sphere, coarse far
        // out (bending falls off as 1/r⁴, so long approach/exit strides leave
        // more of the N_STEPS budget for the strongly curved region)
        float dt = clamp(0.16 * r, 0.03, 1.5);
        // leapfrog (kick-drift-kick) keeps the near-critical orbits stable
        float3 a = -1.5 * h2 * x / (r2 * r2 * r);
        v += a * (0.5 * dt);
        x += v * dt;
        r2 = dot(x, x);
        r  = sqrt(r2);
        a  = -1.5 * h2 * x / (r2 * r2 * r);
        v += a * (0.5 * dt);

        // ---- thin-disk crossing: the ray pierced the disk plane ----
        float s = dot(x, n);
        if (hasDisk && s * sPrev < 0.0 && trans > 0.02) {
            float  tc = sPrev / (sPrev - s);
            float3 xc = mix(xPrev, x, tc);
            float  rc = length(xc);
            if (rc > rin && rc < rout) {
                float band = smoothstep(rin, rin * 1.25, rc)
                           * (1.0 - smoothstep(rout * 0.70, rout, rc));

                // disk-plane polar coords for the streak texture
                float phi   = atan2(dot(xc, e2), xc.x);
                float turns = phi / 6.2831853;
                float kep   = pow(rin / rc, 1.5);
                // √(1 − 1.5/r): time runs slower for the inner orbits — the
                // pattern visibly freezes toward the inner edge
                float gloc  = sqrt(max(1.0 - 1.5 / rc, 0.02));
                float swirl = rc * u.diskWind * 0.12 - t * kep * spd * gloc * sdir;
                float streaks = vnoiseWrapY(float2(rc * 2.8, turns * 19.0 + swirl * 3.0), 19.0) * 0.65 +
                                vnoiseWrapY(float2(rc * 1.0, turns * 9.0  + swirl * 1.5 + 7.0), 9.0) * 0.35;
                streaks = 0.35 + u.diskContrast * streaks * streaks;

                // relativistic Doppler + gravitational shift for gas on a
                // circular geodesic: g = √(1 − 1.5/r) / (1 − β·k̂), with the
                // photon direction at the crossing taken from the ray itself
                float3 gasdir = normalize(cross(n, xc)) * sdir;
                float  beta   = clamp(rsqrt(max(2.0 * (rc - 1.0), 0.2)), 0.0, 0.99);
                float  g      = gloc / max(1.0 + beta * dot(gasdir, normalize(v)), 0.05);
                g = mix(1.0, g, u.dopplerMix);

                // Shakura–Sunyaev temperature profile, peak normalized to 1
                float  xpr   = max(1.0 - sqrt(rin / rc), 0.0);
                float  tprof = pow(rin / rc, 0.75) * pow(xpr, 0.25) / 0.488;
                float3 cbb   = blackbody(u.diskTemp * tprof * g);  // shifted color
                float  boost = pow(g, u.diskBeam);                 // beaming

                float density = band * streaks;
                emitc += trans * cbb * (u.diskGain * 2.2 * density * tprof * tprof * boost);
                trans *= 1.0 - clamp(u.diskOpacity * density, 0.0, 1.0);
            }
        }
        sPrev = s;
        xPrev = x;
    }
    // rays still wound up near the photon sphere when the budget ran out are
    // as good as captured
    if (!captured && dot(x, x) < 4.0) captured = true;

    // ---- background: where did the escaped ray come from? ----
    float3 bg = space;
    if (!captured) {
        float3 d = normalize(v);
        if (u.starGain > 0.001) bg += stars(d, t) * u.starGain * window;
        if (d.z < -0.05) {
            // project the straight exit ray onto the desktop sky plane at
            // z = -lensDepth and map back to screen space
            float  tpl = (-u.lensDepth - x.z) / d.z;
            float3 hp  = x + d * tpl;
            float2 q   = rot2(hp.xy, -u.diskRoll) / W;
            float2 sp  = float2(q.x, -q.y);
            // the *displacement* is faded by the window, never the color —
            // a continuous warp leaves no seam at the far-field boundary
            float2 suv = u.center + (p + (sp - p) * window) / float2(aspect, 1.0);
            // rays bent past ~90° never reach the sky plane behind the hole;
            // they fade to the starfield instead of sampling garbage
            float toward = smoothstep(0.05, 0.35, -d.z);
            bg += screen.sample(smp, suv).rgb * toward * u.hasCapture;
        }
    }

    // disk light is HDR; tonemap it on top of the background sample
    float3 col = bg * trans + (float3(1.0) - exp(-emitc * u.exposure));
    return float4(col, 1.0);
}
