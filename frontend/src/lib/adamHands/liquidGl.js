// WebGL ribbon / silk renderer for the hero's liquid field (design spec
// 20261024-verses-depth-liquid, section 4). A domain-warped fbm scalar field is mapped through
// iso-level bands, so thin luminous lines bundle, fold and pinch like the reference silk, then
// recoloured into the warm palette. One transparent canvas over the CSS underlay; no libraries.
// Pure data and small helpers are exported for tests; the GL object code is in createLiquidGl.
import {
  FIELD_DARK, FIELD_DEEP, FIELD_LO, FIELD_ZONE_MAX, ADAM_ZONE, hexRgb,
  LEAK_GOLD, LIGHT_BG,
} from './field.js';

// Lens edge colour at the frame corners (measured from the lens at p = 1.00: about 246,212,150).
const LENS_EDGE = '#F6D496';
export const LIQUID_SCALE = 1.35;
export const LIQUID_T0 = 37; // frozen / start flow time
export const LIQUID_FLOW = 0.045; // flow clock to warp time
// RIBBON_SCALE: the one knob for how big the silk folds are (spatial frequency of the whole ribbon + noise pattern).
// Higher = bigger, broader, fewer waves across the screen; 1.0 = the earlier look, with shader math bit-for-bit
// unchanged (the generated source is identical at 1.0). Ask for "bigger waves / lower frequency" -> raise it, "finer ripples" -> lower it.
// Implementation: the noise coordinate is LIQUID_SCALE / RIBBON_SCALE (see ribbonUvScale), so every fold is RIBBON_SCALE
// times larger on screen, band thickness included. Because the pattern is a uniform magnification, the band shape stays the
// same in iso-band units, so RIBBON_SOFTNESS keeps the SAME relative softness (blur grows with the folds, in px) and
// ribbonCompensation needs no change. Apparent flow speed is held constant by dividing the flow clock by RIBBON_SCALE
// (see ribbonFlow): the pattern drifts through noise space at LIQUID_FLOW/RIBBON_SCALE per second, which is exactly
// RIBBON_SCALE times less noise distance per px, so features travel the same screen pixels per second as at 1.0.
export const RIBBON_SCALE = 2.0;
export const LIQUID_RAMP = [
  { i: 0, c: FIELD_DARK },
  { i: 0.5, c: FIELD_LO },
  { i: 0.85, c: '#D4963A' },
  { i: 1, c: '#F3C48B' },
];
// Ribbon intensity cap inside the text zone: ramp(I_ZONE_MAX) is no lighter than FIELD_ZONE_MAX.
export const LIQUID_I_ZONE_MAX = 0.54;
// RIBBON_SOFTNESS: the one knob for how blurry the moving liquid lines are. It multiplies the width of
// the ribbon band falloff in the shader (the halo widens with its square root, so wide settings melt into
// each other). 1.0 = the original crisp silk lines; larger = softer, blurrier streaks (2.5 to 4 reads as
// smooth flowing liquid light); 0.5 would be sharper than the original. Line amplitude is scaled by softness^-0.4 so overall
// brightness stays near the crisp look; the text-zone luminance cap and palette are unaffected. Ask for "more blur" -> raise it, "less" -> lower it.
// Above RIBBON_SOFT_REF the widening bands start to fill the gaps (gap level up, contrast down), so
// ribbonCompensation(S) linearly remaps the band profile so gap level and peak equal the RIBBON_SOFT_REF look (full contrast back). Identity at or below RIBBON_SOFT_REF.
export const RIBBON_SOFTNESS = 7.2; // 1.0 originally; 2.4 after the first soften round; 7.2 = 3x that (2026-10-24)
export const RIBBON_SOFT_REF = 2.4; // the validated look the compensation holds brightness and gap darkness to
export const RIBBON_LINE_W = 0.16; // band half-width in iso-band units at RIBBON_SOFTNESS = 1
export const RIBBON_HALO_W = 0.55;
export const LIQUID_ZONE_FEATHER = 0.08;
export const LIQUID_RES = { desktop: { k: 0.5, maxW: 960, maxH: 540, fps: 60, oct: 4, warp2: true }, mobile: { k: 0.35, maxW: 640, maxH: 640, fps: 30, oct: 3, warp2: false } };
export const LIQUID_SCROLL = { k: 1 / 1500, maxBoost: 1.5 }; // flow speed boost per px/s of scroll, capped (total <= 2.5x)

// Raw band profile across one iso-band cycle (d = 0 band centre .. 1 gap centre), before env: line + halo.
const ribbonRaw = (d, S) => Math.pow(S, -0.4) * Math.exp(-((d / (RIBBON_LINE_W * S)) ** 2)) + 0.22 * Math.exp(-((d / (RIBBON_HALO_W * Math.sqrt(S))) ** 2));
const ribbonStats = (S) => ({ hi: ribbonRaw(0, S), lo: ribbonRaw(1, S) });
// Returns { gain, offset }: profile' = raw * gain + offset. The gap level (lo) and the peak (hi) are kept at the RIBBON_SOFT_REF
// values, i.e. the full band-to-gap contrast of the 2.4 look is restored while the band shape stays as wide as S makes it. Mean
// brightness then rises a little (wider bands carry more light); that is the glow of a softer band. Identity for S <= RIBBON_SOFT_REF.
export function ribbonCompensation(S = RIBBON_SOFTNESS) {
  if (S <= RIBBON_SOFT_REF) return { gain: 1, offset: 0 };
  const ref = ribbonStats(RIBBON_SOFT_REF); const cur = ribbonStats(S);
  const gain = (ref.hi - ref.lo) / (cur.hi - cur.lo);
  return { gain, offset: ref.lo - gain * cur.lo };
}

// Noise-space size of the screen height (shader uv multiplier) and flow-clock multiplier for a given RIBBON_SCALE.
export const ribbonUvScale = (scale = RIBBON_SCALE) => LIQUID_SCALE / scale;
export const ribbonFlow = (scale = RIBBON_SCALE) => LIQUID_FLOW / scale;
// GLSL float literal without trailing zero noise: 1.35 -> "1.35", 0.045 -> "0.045", 0.675 -> "0.675".
const glf = (v) => { const t = Number(v.toFixed(6)).toString(); return /[.e]/.test(t) ? t : `${t}.0`; };

const lerp = (a, b, t) => a + (b - a) * t;
const hexV = (hex) => hexRgb(hex).map((v) => v / 255);

// JS mirror of the GLSL ramp (0..1 RGB), used by tests and to build the shader constants.
export function liquidRamp(I) {
  const x = Math.min(1, Math.max(0, I));
  for (let k = 1; k < LIQUID_RAMP.length; k += 1) {
    const a = LIQUID_RAMP[k - 1]; const b = LIQUID_RAMP[k];
    if (x <= b.i) { const t = (x - a.i) / (b.i - a.i); const ca = hexV(a.c); const cb = hexV(b.c); return ca.map((v, j) => lerp(v, cb[j], t)); }
  }
  return hexV(LIQUID_RAMP[LIQUID_RAMP.length - 1].c);
}

// Zone rectangle in GL uv (origin bottom-left): [x0, x1, y0, y1], 0..1.
export function liquidZone(mobile) {
  const z = mobile ? ADAM_ZONE.mobile : ADAM_ZONE.desktop;
  return [z.x[0] / 100, z.x[1] / 100, 1 - z.y[1] / 100, 1 - z.y[0] / 100];
}

export function internalSize(cssW, cssH, mobile, dpr = 1) {
  const r = mobile ? LIQUID_RES.mobile : LIQUID_RES.desktop;
  const d = Math.min(1, dpr);
  const w = Math.max(2, Math.min(r.maxW, Math.round(cssW * r.k * d)));
  const h = Math.max(2, Math.min(r.maxH, Math.round(cssH * r.k * d)));
  return [w, h];
}

const f3 = (c) => `vec3(${hexV(c).map((v) => v.toFixed(4)).join(',')})`;

export function fragmentSource({ oct, warp2, softness = RIBBON_SOFTNESS, scale = RIBBON_SCALE }) {
  const lw = (RIBBON_LINE_W * softness).toFixed(4);
  const amp = Math.pow(softness, -0.4).toFixed(4); // keeps mean brightness near the crisp look as bands widen
  const hw = (RIBBON_HALO_W * Math.sqrt(softness)).toFixed(4);
  const comp = ribbonCompensation(softness);
  return `
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
#define OCT ${oct}
#define RIBBON_SOFTNESS ${softness.toFixed(3)}
#define RIBBON_SCALE ${scale.toFixed(3)}
#define NORM ${oct === 4 ? '0.9375' : '0.875'}
uniform vec2 uRes;
uniform float uTime;
uniform vec4 uZone;
uniform float uH;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123); }
float vnoise(vec2 p) {
  vec2 i = floor(p); vec2 f = fract(p); vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float fbm(vec2 p) {
  float a = 0.5; float s = 0.0;
  mat2 R = mat2(0.8, 0.6, -0.6, 0.8);
  for (int i = 0; i < OCT; i++) { s += a * vnoise(p); p = R * p * 2.0 + vec2(7.3, 3.1); a *= 0.5; }
  return s / NORM;
}
vec3 ramp(float I) {
  vec3 c0 = ${f3(LIQUID_RAMP[0].c)}; vec3 c1 = ${f3(LIQUID_RAMP[1].c)}; vec3 c2 = ${f3(LIQUID_RAMP[2].c)}; vec3 c3 = ${f3(LIQUID_RAMP[3].c)};
  vec3 c = mix(c0, c1, clamp(I / 0.5, 0.0, 1.0));
  c = mix(c, c2, clamp((I - 0.5) / 0.35, 0.0, 1.0));
  return mix(c, c3, clamp((I - 0.85) / 0.15, 0.0, 1.0));
}
void main() {
  vec2 uvn = gl_FragCoord.xy / uRes;
  vec2 uv = (gl_FragCoord.xy / uRes.y) * ${glf(ribbonUvScale(scale))};
  float t = uTime * ${glf(ribbonFlow(scale))};
  vec2 q = vec2(fbm(uv + t * 0.9), fbm(uv + vec2(5.2, 1.3) - t * 0.7));
${warp2 ? `  vec2 r = vec2(fbm(uv + 1.7 * q + vec2(1.7, 9.2) + t * 0.5), fbm(uv + 1.7 * q + vec2(8.3, 2.8) - t * 0.4));` : `  vec2 r = q;`}
  float f = fbm(uv + 1.9 * r);
  f = (f - 0.5) * 2.2 + 0.5;
  float env = smoothstep(0.32, 0.62, fbm(uv * 0.55 + 2.0 * q + 11.0));
  float d = abs(fract(f * 6.5) - 0.5) * 2.0;
  float prof = exp(-pow(d / ${lw}, 2.0)) * ${amp} + exp(-pow(d / ${hw}, 2.0)) * 0.22;
  float I = clamp((prof * ${comp.gain.toFixed(4)} + ${comp.offset.toFixed(4)}) * env, 0.0, 1.0);
  // text-zone luminance cap, feathered
  float fe = ${LIQUID_ZONE_FEATHER.toFixed(3)};
  float zx = smoothstep(uZone.x, uZone.x + fe, uvn.x) * (1.0 - smoothstep(uZone.y - fe, uZone.y, uvn.x));
  float zy = smoothstep(uZone.z, uZone.z + fe, uvn.y) * (1.0 - smoothstep(uZone.w - fe, uZone.w, uvn.y));
  float zm = zx * zy;
  I = mix(I, min(I, ${LIQUID_I_ZONE_MAX.toFixed(3)}), zm);
  vec3 deep = ${f3(FIELD_DEEP)};
  vec3 col = mix(deep, ramp(I), clamp(I * 3.0, 0.0, 1.0));
  float a = clamp(0.15 * (1.0 - env) + I * 0.95, 0.0, 1.0);
  vec3 rgb = col * a; // premultiplied marble
  float al = a;
  // Hand-off (task 20261111-kinetic-type-marble): the lens light is withdrawn along the marble's own folds.
  // veil = 1 is the white hold (same pixels as the lens), veil = 0 is bare marble; the veil edge is an iso-contour of
  // key, which mixes the light falloff, the warped spokes, the fold field f and the ribbon intensity I, so the light
  // survives longest on fold crests and bright ribbons and ends as gold rims. No opacity ramp anywhere.
  float vl = 0.0;
  if (uH < 0.999) {
    vec2 c = (uvn - 0.5) * vec2(uRes.x / uRes.y, 1.0);
    float rr = clamp(length(c) / (0.5 * length(vec2(uRes.x / uRes.y, 1.0))), 0.0, 1.0); // 1 at the frame corners, any aspect
    float an = atan(c.y, c.x);
    float ra = 7.0 * (an + 2.4 * uH * (q.x - 0.5) + 1.4 * uH * (q.y - 0.5)) + 1.3 * sin(3.0 * an);
    float ray = pow(abs(cos(ra)), 16.0);
    // Veil colour = the lens frame (honey edge falling to the white hold, spokes lifted), so veil = 1 at h = 0 is
    // pixel-close to the lens everywhere, not only at the centre. Nothing here is a flat fill.
    float ax = min(uRes.x / uRes.y, 1.0); // portrait: the lens lobes spread across the width, so the glow is wider than round in pixels
    float gx = ax < 1.0 ? ax * 0.45 : 1.0; // landscape: the lens glow is round in screen fractions (x scale 1)
    float rc = clamp(length((uvn - 0.5) * vec2(gx, 1.0)) / (0.5 * length(vec2(gx, 1.0))), 0.0, 1.0);
    float sh = clamp(exp(-pow(max(rc - 0.12, 0.0) / 0.45, 1.5)) + 0.12 * ray * smoothstep(0.9, 1.0, ax) * smoothstep(0.25, 0.5, rc) * (1.0 - 0.5 * rr), 0.0, 1.0); // radial fit to the lens ring means
    vec3 lcol = mix(${f3(LENS_EDGE)}, vec3(1.0), sh);
    // Key field for the contour: smooth radial falloff + fold field + ribbon intensity (no spokes in the key, so the
    // edge follows the coarse fold flow and never forms spikes).
    float Lf = 1.15 - rr + 0.35 * (1.0 - rr) * (1.0 - rr);
    float fc = clamp(f, 0.0, 1.0);
    float key = Lf + 0.80 * (0.5 * (q.x + q.y) - 0.5) + 0.12 * (fc - 0.5) + 0.12 * I; // coarse warp q gives smooth fold-scale contours
    // Threshold sweep: piecewise linear in h, knots measured so the mean frame luminance falls at an even rate (most key
    // values sit between 0.3 and 1.5, so a plain linear T would sit still, then collapse in a few frames). Edges go first
    // (h < 0.04), the body over h 0.04 .. 0.92, the white core last. T runs -0.40 .. 2.25.
    float T = -0.40 + 0.70 * smoothstep(0.0, 0.03, uH) + 0.22 * clamp((uH - 0.03) / 0.09, 0.0, 1.0) + 0.13 * clamp((uH - 0.12) / 0.12, 0.0, 1.0)
      + 0.215 * clamp((uH - 0.24) / 0.26, 0.0, 1.0) + 0.205 * clamp((uH - 0.50) / 0.20, 0.0, 1.0) + 0.33 * clamp((uH - 0.70) / 0.15, 0.0, 1.0)
      + 1.33 * smoothstep(0.85, 1.0, uH);
    float vw = 0.20 + 0.45 * smoothstep(0.55, 1.0, uH); // the veil edge softens as the white core leaves, so it never snaps out
    float veil = smoothstep(T - vw, T + vw, key);
    float rim = 4.0 * veil * (1.0 - veil);
    lcol += ${f3(LEAK_GOLD)} * rim * 0.30;
    vl = veil;
    rgb = rgb * (1.0 - veil) + lcol * veil;
    al = al * (1.0 - veil) + veil;
  }
  // Resolve: the bottom of the pinned stage brightens into cream along a smooth, fold-flowing gradient (no dependence on the
  // fine ribbon intensity, which made the edge ragged), so the cream .hm-fam-rest rises from the stage edge with no seam and no flat strip.
  float yb = 1.0 - uvn.y;
  float qm = 0.5 * (q.x + q.y); // coarse warp only: the resolve edge follows the fold flow smoothly, never the fine ribbon noise
  float rz = smoothstep(0.80 + 0.07 * (0.5 - qm), 0.985, yb);
  float m = clamp(rz * rz * (3.0 - 2.0 * rz) + smoothstep(0.96, 0.985, yb), 0.0, 1.0) * (1.0 - vl * (1.0 - smoothstep(0.03, 0.30, uH))); // the lens frame owns the edge at h = 0; the cream band then forms uniformly under the veil (not along its ragged contour)
  rgb = mix(rgb, ${f3(LIGHT_BG)}, m);
  al = mix(al, 1.0, m);
  gl_FragColor = vec4(rgb, al);
}`;
}

const VERT = 'attribute vec2 p; void main() { gl_Position = vec4(p, 0.0, 1.0); }';

function compile(gl, type, src) {
  const s = gl.createShader(type);
  gl.shaderSource(s, src); gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) { const m = gl.getShaderInfoLog(s); gl.deleteShader(s); throw new Error(`shader: ${m}`); }
  return s;
}

// Returns null when WebGL is unavailable. api: resize(cssW, cssH, dpr), draw(timeSeconds), destroy().
export function createLiquidGl(canvas, { mobile = false, onLost } = {}) {
  if (!canvas || !canvas.getContext) return null;
  if (typeof navigator !== 'undefined' && /jsdom/i.test(navigator.userAgent || '')) return null; // jsdom has no WebGL
  let gl = null;
  try { gl = canvas.getContext('webgl', { alpha: true, premultipliedAlpha: true, antialias: false, depth: false, stencil: false, powerPreference: 'low-power' }); } catch { gl = null; }
  if (!gl) return null;
  const cfg = mobile ? LIQUID_RES.mobile : LIQUID_RES.desktop;
  let prog; let buf;
  try {
    prog = gl.createProgram();
    gl.attachShader(prog, compile(gl, gl.VERTEX_SHADER, VERT));
    gl.attachShader(prog, compile(gl, gl.FRAGMENT_SHADER, fragmentSource(cfg)));
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error('link');
  } catch { return null; }
  gl.useProgram(prog);
  buf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  const loc = gl.getAttribLocation(prog, 'p');
  gl.enableVertexAttribArray(loc);
  gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
  const uRes = gl.getUniformLocation(prog, 'uRes');
  const uTime = gl.getUniformLocation(prog, 'uTime');
  const uZone = gl.getUniformLocation(prog, 'uZone');
  const uH = gl.getUniformLocation(prog, 'uH');
  gl.uniform4fv(uZone, liquidZone(mobile));
  gl.disable(gl.BLEND);
  const lost = (e) => { if (e && e.preventDefault) e.preventDefault(); if (onLost) onLost(); };
  canvas.addEventListener('webglcontextlost', lost);
  let w = 0; let h = 0;
  return {
    resize(cssW, cssH, dpr = 1) {
      const [nw, nh] = internalSize(cssW, cssH, mobile, dpr);
      if (nw === w && nh === h) return;
      w = nw; h = nh; canvas.width = w; canvas.height = h;
      gl.viewport(0, 0, w, h); gl.uniform2f(uRes, w, h);
    },
    draw(time, h = 0) {
      if (!w || gl.isContextLost()) return;
      gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT);
      gl.uniform1f(uTime, time);
      gl.uniform1f(uH, h);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    },
    destroy() {
      canvas.removeEventListener('webglcontextlost', lost);
      try { gl.deleteBuffer(buf); gl.deleteProgram(prog); const x = gl.getExtension('WEBGL_lose_context'); if (x) x.loseContext(); } catch { /* ignore */ }
    },
  };
}

// Flow clock step: dt (s, clamped), scroll speed in px/s. Never more than 2.5x.
export const flowDelta = (dt, scrollSpeed) => Math.min(dt, 1 / 20) * (1 + Math.min(LIQUID_SCROLL.maxBoost, Math.abs(scrollSpeed) * LIQUID_SCROLL.k));
export { FIELD_ZONE_MAX };
