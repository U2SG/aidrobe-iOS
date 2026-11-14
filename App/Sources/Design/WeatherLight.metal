#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Weather as the light on a page laid by a window. Two passes:
//   weatherLighting — how much light reaches each point (multiplied onto a
//                     light page, added to a dark one);
//   weatherAir      — what hangs in the air or sits on the glass, drawn over.
// Every input is a continuous amount (see WeatherVisual), so nothing here
// knows about "kinds" of weather.

static float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

static float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash12(i), hash12(i + float2(1.0, 0.0)), u.x),
               mix(hash12(i + float2(0.0, 1.0)), hash12(i + float2(1.0, 1.0)), u.x), u.y);
}

static float fbm(float2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < 4; i++) {
        value += vnoise(p) * amplitude;
        p = p * 2.03 + float2(8.4, -5.7);
        amplitude *= 0.5;
    }
    return value / 0.9375;
}

// Distance from the window side of the room, 0 beside it … 1 in the far corner.
static float roomDepth(float2 uv, float height, float sunSide) {
    float2 window = float2(sunSide > 0.2 ? 1.0 : 0.0, 0.0);
    return smoothstep(0.1, 1.0, distance(uv, window) / length(float2(1.0, height)));
}

// Share of direct sun reaching this point: through the window, past its bars,
// past a branch outside, past whatever cloud is overhead right now.
static float directSun(float2 uv, float time, float cloud, float wind, float windSide,
                       float humidity, float dust, float elevation, float sunSide) {
    // Low sun throws the window long and slanted; high sun drops it short and upright.
    float shear = sunSide * (0.16 + 0.75 * (1.0 - elevation));
    float2 q = float2(uv.x - 0.5 - shear * (uv.y - 0.9), uv.y - 0.07 * sunSide * (uv.x - 0.5));
    float top = 0.11;
    float bottom = top + 1.45 + (1.0 - elevation) * 0.7;

    // Shadows soften with distance from what casts them, and in thick air.
    float soft = (0.010 + humidity * 0.010 + dust * 0.035 + cloud * 0.008) * (0.6 + uv.y * 0.55);
    float halfWidth = 0.60;
    float inside = smoothstep(halfWidth + soft, halfWidth - soft, abs(q.x))
                 * smoothstep(top - soft, top + soft, q.y)
                 * smoothstep(bottom + soft, bottom - soft, q.y);
    float bar = 0.017;
    float bars = smoothstep(bar - soft, bar + soft, abs(q.x));
    float third = (bottom - top) / 3.0;
    bars *= smoothstep(bar - soft, bar + soft, abs(q.y - top - third));
    bars *= smoothstep(bar - soft, bar + soft, abs(q.y - top - 2.0 * third));

    // A branch on the far side from the sun: dappled shade that gusts move.
    float side = sunSide > 0.2 ? -1.0 : 1.0;
    float2 anchor = float2(0.5 + 0.40 * side, 0.36);
    float reach = smoothstep(0.80, 0.10, distance(uv * float2(1.0, 0.8), anchor * float2(1.0, 0.8)));
    float gust = 0.55 + 0.45 * sin(time * 0.7) * sin(time * 0.23 + 1.0);
    float2 sway = float2(sin(time * (0.5 + wind * 1.7)) * (0.005 + wind * 0.04 * gust) + sin(time * 0.19) * 0.004,
                         cos(time * (0.37 + wind * 1.3)) * (0.003 + wind * 0.022 * gust));
    float canopy = fbm((uv + sway) * 5.2 + float2(3.1, 7.7)) * 0.68 + fbm((uv + sway * 1.7) * 11.5) * 0.32;
    float edge = 0.045 + soft * 2.2;
    float leaves = smoothstep(0.50 - edge, 0.50 + edge, canopy + (reach - 0.9) * 0.45) * smoothstep(0.0, 0.35, reach);

    // Cloud shadow sweeping over, faster in wind. More cover, less sun between.
    float2 drift = float2(-time * (0.010 + wind * 0.075) * windSide, time * 0.004);
    float field = fbm(float2(uv.x * 0.85, uv.y * 0.65) + drift + 11.0);
    float gap = 1.0 - cloud;
    float shadowed = smoothstep(gap - 0.20, gap + 0.20, field * 1.1);

    return inside * bars * (1.0 - leaves * 0.9) * (1.0 - shadowed);
}

[[ stitchable ]] half4 weatherLighting(float2 position, half4 color, float2 size, float time, float dark,
                                       float sun, float cloud, float rain, float snow, float fog, float dust,
                                       float wind, float windSide, float humidity, float warmth,
                                       float elevation, float sunSide, float night, float flash) {
    float2 uv = position / size.x;
    float height = size.y / size.x;
    float lit = sun > 0.01 ? directSun(uv, time, cloud, wind, windSide, humidity, dust, elevation, sunSide) * sun : 0.0;
    float depth = roomDepth(uv, height, sunSide);
    float wet = max(rain, snow * 0.5);

    // A lamp after dark: a pool from one side of the table.
    float pool = smoothstep(1.9, 0.0, distance(uv, float2(0.16, 0.22)));

    if (dark > 0.5) {
        // Dark page: add the light that is there.
        float3 sunTone = mix(float3(1.0, 0.80, 0.56), float3(1.0, 0.62, 0.34), (1.0 - elevation) * 0.85);
        float3 light = sunTone * lit * 0.095;
        // Grey days still glow, coolly, from the window side.
        light += float3(0.42, 0.52, 0.74) * (1.0 - depth) * (1.0 - night)
               * (0.012 + 0.028 * cloud + 0.02 * wet + 0.02 * fog) * (1.0 - lit);
        light += float3(0.55, 0.40, 0.20) * (1.0 - depth) * 0.05 * dust * (1.0 - night);
        light += float3(1.0, 0.70, 0.40) * pool * pool * 0.10 * night;
        light += float3(0.70, 0.80, 1.0) * flash * 0.10;
        return half4(half3(light), 1.0);
    }

    // Light page: multiply. Where sun could fall but doesn't, the page is lit
    // by the sky alone — dimmer and cooler.
    float3 shade = mix(float3(0.85, 0.875, 0.92), float3(0.87, 0.86, 0.85), dust);
    float3 tone = mix(float3(1.0), shade, 0.30 * sun);
    tone *= mix(float3(1.0), float3(0.93, 0.945, 0.97), rain * 0.85);
    tone *= mix(float3(1.0), float3(0.95, 0.97, 1.0), snow);
    tone *= mix(float3(1.0), float3(0.96, 0.955, 0.95), fog * 0.6);
    tone *= mix(float3(1.0), float3(0.97, 0.92, 0.82), dust * 0.75);

    float3 sunTone = mix(float3(1.0, 0.99, 0.965), float3(1.0, 0.955, 0.885), (1.0 - elevation) * 0.85);
    sunTone *= mix(float3(1.0), float3(0.99, 0.95, 0.86), dust * 0.6);
    tone = mix(tone, sunTone, lit);

    // Diffuse daylight falls off into the room; the flatter the day, the more this is all there is.
    tone *= 1.0 - depth * (0.015 + 0.05 * cloud * (1.0 - lit) + 0.035 * wet + 0.03 * fog + 0.03 * dust);
    // Overcast light is never quite still.
    tone *= 1.0 + (fbm(uv * 0.8 + float2(time * 0.012, 0.0)) - 0.5) * 0.035 * cloud * (1.0 - lit);

    float3 lamp = mix(float3(0.78, 0.76, 0.79), float3(1.0, 0.965, 0.89), pool);
    tone = mix(tone, lamp, night);
    tone = mix(tone, float3(1.0), flash * 0.85);
    return half4(half3(clamp(tone, 0.0, 1.0)), 1.0);
}

// MARK: Air and glass

static float4 over(float4 under, float3 rgb, float alpha) {
    alpha = clamp(alpha, 0.0, 1.0);
    return float4(rgb * alpha + under.rgb * (1.0 - alpha), alpha + under.a * (1.0 - alpha));
}

// A bead of water: bends light, so its upper edge reads dark, its lower edge
// bright, with a glint. `d` is the position inside the bead, unit circle.
static float4 bead(float4 acc, float2 d, float presence, float dark) {
    float dist = length(d);
    float body = smoothstep(1.0, 0.82, dist) * presence;
    float3 rim = mix(float3(0.20, 0.27, 0.38), float3(0.0, 0.0, 0.0), dark);
    float3 lit = mix(float3(1.0, 1.0, 1.0), float3(0.80, 0.88, 1.0), dark);
    // Shadow thrown onto the page, down and to the side.
    float shadow = smoothstep(1.0, 0.75, length(d - float2(0.38, 0.55))) * (1.0 - body) * presence;
    acc = over(acc, rim, shadow * mix(0.10, 0.28, dark));
    acc = over(acc, rim, body * (smoothstep(0.25, -1.0, d.y) * mix(0.30, 0.50, dark) + smoothstep(0.55, 1.0, dist) * 0.10));
    acc = over(acc, lit, body * smoothstep(-0.15, 1.0, d.y) * mix(0.80, 0.34, dark));
    acc = over(acc, float3(1.0), smoothstep(0.30, 0.10, length(d - float2(-0.36, -0.46))) * presence * mix(0.95, 0.60, dark));
    return acc;
}

[[ stitchable ]] half4 weatherAir(float2 position, half4 color, float2 size, float time, float dark,
                                  float rain, float snow, float fog, float dust,
                                  float wind, float windSide, float humidity) {
    float2 uv = position / size.x;
    float height = size.y / size.x;
    float y = uv.y / height;
    float4 acc = float4(0.0);

    // Fog: distance washed out, thicker higher up (further off), sliding with the air.
    if (fog > 0.0) {
        float3 veil = mix(float3(0.97, 0.97, 0.96), float3(0.42, 0.42, 0.43), dark);
        float body = fbm(float2(uv.x * 1.2 - time * 0.02 * windSide * (0.5 + wind), uv.y * 1.9));
        acc = over(acc, veil, fog * mix(0.36, 0.17, dark) * mix(1.0, 0.45, y) * (0.7 + 0.6 * body));
    }

    // Dust and sand: a warm, dirty veil that streams, with grain in it when the wind is up.
    if (dust > 0.0) {
        float3 veil = mix(float3(0.91, 0.80, 0.60), float3(0.44, 0.34, 0.20), dark);
        float stream = fbm(float2(uv.x * 1.6 - time * (0.05 + wind * 0.35) * windSide, uv.y * 3.2));
        acc = over(acc, veil, dust * mix(0.26, 0.15, dark) * (0.65 + 0.7 * stream));
        float grain = pow(vnoise(float2((uv.x - time * (0.4 + wind * 1.4) * windSide) * 12.0, uv.y * 320.0)), 10.0);
        acc = over(acc, veil * mix(0.78, 1.35, dark), grain * dust * wind * 0.22);
    }

    // Heavy rain is also seen falling beyond the glass, faintly, slanted by the wind.
    float falling = smoothstep(0.45, 0.95, rain);
    if (falling > 0.0) {
        float2 p = uv;
        p.x += p.y * wind * 0.45 * windSide;
        p *= float2(70.0, 5.5);
        p.y -= time * (9.0 + rain * 5.0);
        float2 cell = floor(p);
        float2 f = fract(p);
        float r = hash12(cell + 3.0);
        float streak = step(0.55, r) * smoothstep(0.08, 0.0, abs(f.x - 0.2 - r * 0.6))
                     * smoothstep(0.0, 0.2, f.y) * smoothstep(1.0, 0.3, f.y);
        acc = over(acc, mix(float3(0.34, 0.41, 0.52), float3(0.76, 0.83, 0.96), dark), streak * falling * mix(0.11, 0.09, dark));
    }

    // Snow at three distances: far flakes small and sharp, near ones large, faint and out of focus.
    if (snow > 0.0) {
        for (int layer = 0; layer < 3; layer++) {
            float scale = layer == 0 ? 16.0 : (layer == 1 ? 9.0 : 4.5);
            float radius = layer == 0 ? 0.05 : (layer == 1 ? 0.085 : 0.10);
            float blur = layer == 0 ? 0.03 : (layer == 1 ? 0.06 : 0.12);
            float pace = layer == 0 ? 0.035 : (layer == 1 ? 0.065 : 0.14);
            float weight = layer == 0 ? 1.0 : (layer == 1 ? 0.75 : 0.28);
            float2 p = uv * scale;
            p.y -= time * pace * scale * (0.8 + snow * 0.5);
            p.x -= time * wind * windSide * pace * scale * 1.6 + p.y * wind * windSide * 0.35;
            float2 cell = floor(p);
            p.x += sin(time * 0.45 + cell.y * 1.7 + float(layer)) * 0.22;
            cell = floor(p);
            float2 f = fract(p);
            float2 center = float2(0.3) + hash22(cell + float(layer) * 31.0) * 0.4;
            float present = step(0.93 - snow * 0.33, hash12(cell + float(layer) * 7.0 + 2.0));
            float flake = smoothstep(radius + blur, radius - blur * 0.5, distance(f, center)) * present * weight;
            // White on paper shows only by the shadow it throws; on a dark page it simply glows.
            float shadow = smoothstep(radius + blur, radius - blur * 0.5, distance(f - float2(0.035, 0.06), center)) * present * weight;
            acc = over(acc, float3(0.44, 0.52, 0.68), shadow * (1.0 - dark) * 0.26);
            acc = over(acc, float3(1.0), flake * mix(0.95, 0.72, dark));
        }
    }

    // Rain on the glass.
    if (rain > 0.0) {
        // Beads that sit, swell and dry.
        float cells = 20.0 + rain * 8.0;
        float2 p = uv * cells;
        float2 cell = floor(p);
        float2 h = hash22(cell);
        float chance = hash12(cell + 19.0);
        float life = fract(hash12(cell + 5.0) + time * 0.010);
        float presence = step(0.94 - rain * 0.32, chance) * clamp(sin(life * 3.14159) * 2.4, 0.0, 1.0);
        float size1 = 0.07 + 0.17 * h.x * h.x;
        float2 d = (fract(p) - (float2(0.3) + h * 0.4)) / float2(size1, size1 * 1.2);
        if (presence > 0.0 && length(d - float2(0.2, 0.3)) < 1.6) {
            acc = bead(acc, d, presence, dark);
        }

        // Runs: a heavy drop slides down in fits and starts, leaving a wet track that thins behind it.
        float columns = 5.0 + rain * 6.0;
        float column = floor(uv.x * columns);
        float hc = hash12(float2(column, 3.7));
        if (hc > 0.62 - rain * 0.42) {
            float pace = (0.035 + hash12(float2(column, 9.1)) * 0.07) * (0.7 + rain * 0.7);
            float travel = height + 0.5;
            float slide = time * pace + sin(time * 0.9 + hc * 40.0) * 0.018;
            float head = fract(hc * 7.0 + slide / travel) * travel - 0.25;
            float wobble = sin(uv.y * 9.0 + hc * 40.0) * 0.007 + sin(uv.y * 23.0 + hc * 17.0) * 0.0025
                         + uv.y * wind * windSide * 0.03;
            float dx = (fract(uv.x * columns) - 0.5) / columns * 0.55 - wobble;
            float dy = uv.y - head;
            float size2 = 0.011 + hash12(float2(column, 1.3)) * 0.005;
            float length2 = 0.22 + hash12(float2(column, 6.6)) * 0.35;
            if (dy < 0.0 && dy > -length2) {
                float fade = 1.0 + dy / length2;
                float width = size2 * 0.42 * (0.35 + 0.65 * fade);
                float track = smoothstep(width, width * 0.35, abs(dx)) * fade;
                acc = over(acc, mix(float3(1.0), float3(0.80, 0.88, 1.0), dark), track * mix(0.42, 0.14, dark));
                float edge = smoothstep(width * 1.6, width, abs(dx - width)) * smoothstep(width * 0.4, width, abs(dx - width) + width * 0.6) * fade;
                acc = over(acc, float3(0.22, 0.29, 0.40), edge * (1.0 - dark) * 0.06);
            }
            acc = bead(acc, float2(dx, dy) / float2(size2, size2 * 1.35), 1.0, dark);
        }
    }

    return half4(acc);
}
