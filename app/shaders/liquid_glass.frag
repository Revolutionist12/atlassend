#version 460 core
// AtlasSend: the "liquid glass" lens of the tab bar, ported from the user's
// "Liquid Glass Tab Bar" design (WebGL). Coordinates are logical pixels of the
// painted area; the bar itself is rendered into `tex` first.

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 res;    // size of the painted area (= texture size in logical px)
uniform vec2 lc;     // lens center
uniform vec2 lb;     // lens half size
uniform float lr;    // lens corner radius
uniform float a;     // lens visibility 0..1
uniform vec2 bc;     // bar center
uniform vec2 bb;     // bar half size
uniform float br;    // bar corner radius
uniform vec4 fill;   // glass body where nothing lies behind the lens (premultiplied)
uniform vec4 rimCol; // rim highlight (premultiplied)

uniform sampler2D tex;

out vec4 fragColor;

float sdf(vec2 p) {
  vec2 q = abs(p - lc) - lb + lr;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - lr;
}

float bsdf(vec2 p) {
  vec2 q = abs(p - bc) - bb + br;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - br;
}

vec4 smp(vec2 p) {
  return texture(tex, clamp(p / res, vec2(0.0), vec2(1.0)));
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec4 base = smp(p);
  if (a <= 0.001) {
    fragColor = base;
    return;
  }

  float d = sdf(p);

  // Soft outer shadow (wide, low, smooth falloff), as premultiplied black.
  float so = max(d, 0.0) / 9.0;
  float sh = exp(-so * so * 2.2) * step(0.0, d) * 0.22 * a;
  vec4 col = vec4(base.rgb * (1.0 - sh), base.a + sh * (1.0 - base.a));

  if (d < 1.0) {
    vec2 e = vec2(1.0, 0.0);
    vec2 n = normalize(vec2(sdf(p + e.xy) - sdf(p - e.xy), sdf(p + e.yx) - sdf(p - e.yx)) + 1e-5);
    float s = max(-d, 0.0); // depth inside the lens (0 at the rim)

    // (1) Top / bottom flats: the rim looks slightly past itself.
    float Ev = 10.0; // thickness of the refracting rim (the original used 18)
    float A = 2.6;
    float uv = clamp(s / Ev, 0.0, 1.0);
    float hv = 0.12 * uv + 0.88 * uv * uv * (2.0 - uv);
    float fv = (s < Ev) ? (-A + (Ev + A) * hv) : s;

    // (2) Rounded ends: content is pulled inward and stretched toward the rim,
    //     so letters bend along the edge.
    float Eh = 12.0;
    float B = 0.46 * Eh;
    float uh = clamp(s / Eh, 0.0, 1.0);
    float fh = s + B * (1.0 - uh) * (1.0 - uh);

    float vert = smoothstep(0.55, 0.92, abs(n.y));
    // Where the glass hangs past the bar, use the outward model so the bar is
    // never dragged into the empty part of the lens.
    vert = max(vert, smoothstep(-2.0, 1.0, bsdf(p)));
    float f = mix(fh, fv, vert);
    float u = mix(uh, uv, vert);

    vec2 sp = p + n * (s - f);
    float w = (1.0 - u);
    w *= w; // dispersion only in the band
    float ca = 1.3 * w;

    vec4 lens = vec4(0.0);
    for (int i = -2; i <= 2; i++) {
      vec2 o = n * float(i) * 0.9 * w;
      vec4 cr = smp(sp + o + n * ca);
      vec4 cg = smp(sp + o);
      vec4 cb = smp(sp + o - n * ca);
      lens += vec4(cr.r, cg.g, cb.b, cg.a);
    }
    lens /= 5.0;
    lens += fill * (1.0 - lens.a);
    lens.rgb += 0.012 * lens.a;

    // Thin soft rim, brighter at the top.
    float rx = (d + 0.5) / 0.45;
    float rim = exp(-rx * rx);
    float topLight = 0.55 + 0.45 * clamp(-n.y, 0.0, 1.0);
    lens = mix(lens, rimCol, rim * 0.28 * topLight);

    float m = (1.0 - smoothstep(-0.6, 0.6, d)) * a;
    col = mix(col, lens, m);
  }

  fragColor = col;
}
