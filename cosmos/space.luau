-- Cosmos' sky, drawn on the GPU: two WGSL fills.
--
--   space.SKY    stars, a nebula and (optionally) a ringed planet over
--                whatever is behind the box. It ignores time, so it is painted
--                once and costs nothing while the window rests.
--   space.ORBIT  a whole scene for a new chat's wallpaper: the view from low
--                orbit. Time moves its clouds and twinkles its stars.
--
-- Both read their look from `shader_params` (four vec4s; zgx resolves a theme
-- token only in the first, which is why the tint goes there).

local M = {}

-- Shared pieces: hashes, value noise, and a layer of stars on a jittered grid.
local COMMON = [[
fn cz_h1(p: vec2<f32>) -> f32 {
 var q = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
 q = q + dot(q, q.yzx + 33.33);
 return fract((q.x + q.y) * q.z);
}
fn cz_h2(p: vec2<f32>) -> vec2<f32> {
 var q = fract(vec3<f32>(p.x, p.y, p.x) * vec3<f32>(0.1031, 0.1030, 0.0973));
 q = q + dot(q, q.yzx + 33.33);
 return fract((q.xx + q.yz) * q.zy);
}
fn cz_noise(p: vec2<f32>) -> f32 {
 let i = floor(p);
 let f = fract(p);
 let u = f * f * (3.0 - 2.0 * f);
 let a = cz_h1(i);
 let b = cz_h1(i + vec2<f32>(1.0, 0.0));
 let c = cz_h1(i + vec2<f32>(0.0, 1.0));
 let d = cz_h1(i + vec2<f32>(1.0, 1.0));
 return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
fn cz_fbm(p0: vec2<f32>) -> f32 {
 var p = p0;
 var amp = 0.5;
 var sum = 0.0;
 for (var i = 0; i < 5; i++) {
  sum = sum + amp * cz_noise(p);
  p = vec2<f32>(0.8 * p.x - 0.6 * p.y, 0.6 * p.x + 0.8 * p.y) * 2.02 + vec2<f32>(11.7, 5.3);
  amp = amp * 0.5;
 }
 return sum;
}
// One layer of stars: a grid of `cell` points, a star in `chance` of its
// cells, `size` points across at its brightest. rgb is the star's colour,
// a its light there. `twinkle` (0 to 1) dims each on a beat of its own.
fn cz_stars(p: vec2<f32>, cell: f32, chance: f32, size: f32, seed: f32, flare: f32, time: f32, twinkle: f32) -> vec4<f32> {
 let g = p / cell;
 let id = floor(g) + vec2<f32>(seed, seed * 1.7);
 if (cz_h1(id * 1.31 + 3.1) > chance) { return vec4<f32>(0.0); }
 let f = fract(g);
 let at = 0.18 + 0.64 * cz_h2(id);
 let d = (f - at) * cell;
 let r = length(d);
 let mag = pow(cz_h1(id + 7.7), 2.6);
 let rad = size * (0.5 + 0.9 * mag);
 var light = (0.3 + 0.7 * mag) * exp(-(r * r) / (rad * rad));
 light = light + flare * 0.22 * mag * exp(-r / (rad * 2.6));
 // The brightest wear a cross, as a lens gives them.
 let arm = rad * 7.0 * flare;
 if (arm > 0.0) {
  let cross = exp(-abs(d.x) / arm) * exp(-abs(d.y) / 0.55) + exp(-abs(d.y) / arm) * exp(-abs(d.x) / 0.55);
  light = light + 0.55 * mag * mag * cross;
 }
 let beat = 0.5 + 0.5 * sin(time * (0.6 + 2.2 * cz_h1(id + 21.0)) + 6.2832 * cz_h1(id + 31.0));
 light = light * (1.0 - twinkle * 0.65 * beat);
 let warm = cz_h1(id + 11.3);
 var col = mix(vec3<f32>(0.74, 0.84, 1.0), vec3<f32>(1.0, 0.95, 0.9), smoothstep(0.35, 0.7, warm));
 col = mix(col, vec3<f32>(1.0, 0.82, 0.62), smoothstep(0.86, 1.0, warm));
 return vec4<f32>(col, clamp(light, 0.0, 1.0));
}
// `src` (straight alpha) laid over `acc` (premultiplied).
fn cz_over(acc: vec4<f32>, src: vec4<f32>) -> vec4<f32> {
 let a = clamp(src.a, 0.0, 1.0);
 return vec4<f32>(src.rgb * a + acc.rgb * (1.0 - a), a + acc.a * (1.0 - a));
}
// A second and third hue for a nebula, turned from the tint.
fn cz_hue2(t: vec3<f32>) -> vec3<f32> { return mix(t.brg, vec3<f32>(1.0, 0.36, 0.62), 0.35); }
fn cz_hue3(t: vec3<f32>) -> vec3<f32> { return mix(t.gbr, vec3<f32>(0.25, 0.85, 0.95), 0.45); }
]]

-- The window's sky.
-- params[0]: the tint (the accent): the nebula's first hue, the planet's air.
-- params[1]: stars (0 to 1), nebula (0 to 1), light theme (0 or 1), seed.
-- params[2]: the planet: its centre from the left and from the bottom, its
--            radius (0: none), its ring (0 or 1). Points.
-- params[3]: how far the sky fades toward the box's bottom (0: not at all).
M.SKY = ui.shader(COMMON .. [[
fn fill(input: FillInput) -> vec4<f32> {
 let tint = input.params[0].rgb;
 let stars = input.params[1].x;
 let cloud = input.params[1].y;
 let light = input.params[1].z;
 let seed = input.params[1].w;
 let p = input.p;
 let uv = p / max(input.size, vec2<f32>(1.0));
 var acc = vec4<f32>(0.0);

 // The nebula: two warped clouds along a band from the bottom left up to
 // the top right, and a faint wash of the tint so no part is flat.
 if (cloud > 0.0) {
  let q = p / 460.0 + vec2<f32>(seed * 3.7, seed * 1.3);
  let warp = vec2<f32>(cz_fbm(q + vec2<f32>(3.1, 0.0)), cz_fbm(q + vec2<f32>(9.2, 1.7)));
  let n1 = cz_fbm(q * 1.25 + warp * 1.5);
  let n2 = cz_fbm(q * 0.9 - warp * 1.2 + vec2<f32>(40.0, 13.0));
  let n3 = cz_fbm(q * 2.1 + warp * 0.8 + vec2<f32>(7.0, 71.0));
  let along = (uv.x * 0.55 + (1.0 - uv.y) * 0.75 - 0.62) / 0.5;
  let band = 0.35 + 0.65 * exp(-along * along);
  let a1 = smoothstep(0.42, 0.82, n1) * band;
  let a2 = smoothstep(0.48, 0.86, n2) * band;
  let a3 = smoothstep(0.55, 0.9, n3) * 0.6;
  var neb = tint * a1 + cz_hue2(tint) * a2 * 0.85 + cz_hue3(tint) * a3 * 0.5;
  let na = clamp(a1 * 0.55 + a2 * 0.5 + a3 * 0.25 + 0.05 * band, 0.0, 1.0);
  neb = neb / max(a1 + a2 * 0.85 + a3 * 0.5, 0.001);
  neb = mix(tint, neb, clamp((a1 + a2 + a3) * 4.0, 0.0, 1.0));
  acc = cz_over(acc, vec4<f32>(neb, na * cloud * mix(0.42, 0.3, light)));
 }

 // Stars: a fine dust, a middle field, and a few bright ones.
 if (stars > 0.0) {
  // (A dark theme's are light; a light theme's are ink.)
  let ink = vec3<f32>(0.2, 0.22, 0.5);
  var s = cz_stars(p, 23.0, 0.55, 0.62, seed + 1.0, 0.0, 0.0, 0.0);
  acc = cz_over(acc, vec4<f32>(mix(s.rgb, ink, light), s.a * stars * mix(0.75, 0.5, light)));
  s = cz_stars(p, 61.0, 0.5, 1.0, seed + 5.0, 0.6, 0.0, 0.0);
  acc = cz_over(acc, vec4<f32>(mix(s.rgb, ink, light), s.a * stars * mix(0.95, 0.6, light)));
  s = cz_stars(p, 173.0, 0.42, 1.5, seed + 9.0, 1.0, 0.0, 0.0);
  acc = cz_over(acc, vec4<f32>(mix(s.rgb, ink, light), s.a * stars * mix(1.0, 0.65, light)));
 }

 // The planet: a banded giant lit from the top right, its air glowing in
 // the tint, a ring round it tilted toward us.
 let R = input.params[2].z;
 if (R > 0.5) {
  let c = vec2<f32>(input.params[2].x, input.size.y - input.params[2].y);
  let d = p - c;
  let r = length(d);
  let aa = 1.0 / max(input.scale, 1.0);
  // The ring's plane: turned, then squashed.
  let ang = -0.42;
  let e = vec2<f32>(d.x * cos(ang) - d.y * sin(ang), d.x * sin(ang) + d.y * cos(ang));
  let rr = length(vec2<f32>(e.x, e.y / 0.3)) / R;
  var ring = 0.0;
  if (input.params[2].w > 0.5) {
   ring = smoothstep(1.32, 1.36, rr) * (1.0 - smoothstep(2.12, 2.18, rr));
   // (Its lanes, and the gap in it.)
   ring = ring * (0.55 + 0.45 * cz_noise(vec2<f32>(rr * 38.0, 1.5)));
   ring = ring * (1.0 - 0.85 * smoothstep(0.035, 0.015, abs(rr - 1.78)));
  }
  let ring_col = mix(vec3<f32>(0.86, 0.8, 0.72), tint, 0.3);
  // Its air, outside the limb.
  let lit = clamp(0.5 + 0.5 * dot(normalize(d + vec2<f32>(0.001)), normalize(vec2<f32>(0.6, -0.8))), 0.0, 1.0);
  let air = exp(-max(r - R, 0.0) / (R * 0.11)) * (0.12 + 0.5 * lit);
  acc = cz_over(acc, vec4<f32>(mix(tint, vec3<f32>(1.0), 0.25), air * step(R, r)));
  // The ring's far half, behind the planet.
  if (e.y < 0.0) { acc = cz_over(acc, vec4<f32>(ring_col * 0.8, ring * 0.5)); }
  // The planet.
  if (r < R + aa) {
   let n2 = d / R;
   let nz = sqrt(max(1.0 - dot(n2, n2), 0.0));
   let n = vec3<f32>(n2.x, n2.y, nz);
   let L = normalize(vec3<f32>(0.58, -0.62, 0.52));
   let lam = clamp(dot(n, L), 0.0, 1.0);
   // (Bands along its turned latitude, pulled about by a little weather.)
   let lat = n2.x * sin(ang) + n2.y * cos(ang);
   let lon = n2.x * cos(ang) - n2.y * sin(ang);
   let weather = cz_fbm(vec2<f32>(lon * 2.2 + 3.0, lat * 9.0 + seed));
   let bands = 0.5 + 0.5 * sin(lat * 15.0 + (weather - 0.5) * 3.2);
   let dark = mix(vec3<f32>(0.16, 0.14, 0.32), tint * 0.5, 0.35);
   let pale = mix(vec3<f32>(0.78, 0.66, 0.74), tint, 0.35);
   var col = mix(dark, pale, bands * 0.75 + weather * 0.25);
   // (Lit, with a night side that never goes quite black, and the air
   // catching light at the limb.)
   col = col * (0.07 + 1.05 * pow(lam, 0.85));
   col = col + mix(tint, vec3<f32>(1.0), 0.3) * pow(1.0 - nz, 3.0) * (0.1 + 0.55 * lam);
   // (The ring's shadow across it.)
   let sh = length(vec2<f32>(e.x + 0.25 * R, (e.y + 0.3 * R) / 0.3)) / R;
   col = col * (1.0 - 0.35 * input.params[2].w * smoothstep(1.3, 1.4, sh) * (1.0 - smoothstep(2.0, 2.2, sh)));
   col = mix(col, vec3<f32>(0.8, 0.78, 0.93), 0.3 * light);
   acc = cz_over(acc, vec4<f32>(col, smoothstep(R + aa, R - aa, r)));
  }
  // The ring's near half, over it.
  if (e.y >= 0.0) { acc = cz_over(acc, vec4<f32>(ring_col, ring * 0.72)); }
 }

 let fade = input.params[3].x;
 if (fade > 0.0) { acc = acc * (1.0 - fade * smoothstep(0.25, 1.0, uv.y)); }
 return vec4<f32>(acc.rgb / max(acc.a, 0.0001), acc.a);
}
]])

-- The view from low orbit, for a new chat's wallpaper.
-- params[0]: the tint (the accent).
-- params[1]: where the pointer is from the middle (x, y: -0.5 to 0.5), how
--            far things move for it (points), twinkle (0 to 1).
-- params[2]: (unused), seed.
M.ORBIT = ui.shader(COMMON .. [[
fn fill(input: FillInput) -> vec4<f32> {
 let tint = input.params[0].rgb;
 let look = input.params[1].xy * input.params[1].z;
 let twinkle = input.params[1].w;
 let seed = input.params[2].y;
 let t = input.time;
 let size = max(input.size, vec2<f32>(1.0));
 let p = input.p;
 let uv = p / size;

 // Space: nearly black, a little bluer toward the horizon.
 var col = mix(vec3<f32>(0.012, 0.016, 0.045), vec3<f32>(0.035, 0.04, 0.11), smoothstep(0.0, 1.0, uv.y));
 col = mix(col, tint * 0.16, 0.35 * smoothstep(0.3, 1.0, uv.y));

 // The nebula, far away: it moves least.
 let ps = p + look * 0.35;
 let q = ps / 520.0 + vec2<f32>(seed * 3.7 + t * 0.004, seed * 1.3);
 let warp = vec2<f32>(cz_fbm(q + vec2<f32>(3.1, 0.0)), cz_fbm(q + vec2<f32>(9.2, 1.7)));
 let n1 = cz_fbm(q * 1.25 + warp * 1.6);
 let n2 = cz_fbm(q * 0.9 - warp * 1.2 + vec2<f32>(40.0, 13.0));
 let n3 = cz_fbm(q * 2.3 + warp * 0.9 + vec2<f32>(7.0, 71.0));
 let along = (uv.x * 0.6 + (1.0 - uv.y) * 0.7 - 0.72) / 0.45;
 let band = 0.25 + 0.75 * exp(-along * along);
 let a1 = smoothstep(0.4, 0.82, n1) * band;
 let a2 = smoothstep(0.46, 0.86, n2) * band;
 let a3 = smoothstep(0.55, 0.9, n3) * band;
 col = col + tint * a1 * 0.5 + cz_hue2(tint) * a2 * 0.42 + cz_hue3(tint) * a3 * 0.22;
 // (Dust lanes across it.)
 col = col * (1.0 - 0.35 * smoothstep(0.5, 0.75, cz_fbm(q * 3.1 + warp * 2.0 + vec2<f32>(90.0, 4.0))) * band);

 // Stars, three depths, each moving a little more than the last.
 var s = cz_stars(p + look * 0.45, 19.0, 0.6, 0.6, seed + 1.0, 0.0, t, twinkle * 0.5);
 col = col + s.rgb * s.a * 0.8;
 s = cz_stars(p + look * 0.6, 53.0, 0.55, 1.05, seed + 5.0, 0.7, t, twinkle);
 col = col + s.rgb * s.a;
 s = cz_stars(p + look * 0.8, 151.0, 0.45, 1.7, seed + 9.0, 1.0, t, twinkle);
 col = col + s.rgb * s.a * 1.1;

 // A moon, small and high, a crescent of it lit.
 let mc = vec2<f32>(size.x * 0.8, size.y * 0.2) - look * 1.2;
 let mR = clamp(min(size.x, size.y) * 0.045, 14.0, 44.0);
 let md = p - mc;
 let mr = length(md);
 let aa = 1.0 / max(input.scale, 1.0);
 if (mr < mR + aa) {
  let n2 = md / mR;
  let nz = sqrt(max(1.0 - dot(n2, n2), 0.0));
  let lam = clamp(dot(vec3<f32>(n2.x, n2.y, nz), normalize(vec3<f32>(-0.7, 0.55, 0.3))), 0.0, 1.0);
  let craters = 0.75 + 0.25 * cz_fbm(n2 * 3.5 + vec2<f32>(4.0, 9.0));
  let moon = vec3<f32>(0.86, 0.85, 0.92) * craters * (0.045 + pow(lam, 0.8));
  col = mix(col, moon, smoothstep(mR + aa, mR - aa, mr));
 }

 // The planet below: its limb an arc across the page's foot, the sun
 // coming up behind it on the left.
 let R = max(size.x, size.y) * 1.25;
 let c = vec2<f32>(size.x * 0.5, size.y * 0.8 + R) - look * 2.0;
 let d = p - c;
 let r = length(d);
 let h = r - R;
 // (Where the sun stands on the limb: a quarter of the way across.)
 let sx = clamp((size.x * 0.24 - c.x) / R, -0.9, 0.9);
 let sun = vec2<f32>(sx, -sqrt(1.0 - sx * sx));
 let off = length(d / max(r, 1.0) - sun);
 let toward = 0.12 + 0.88 * exp(-(off * off) / 0.05);
 // (Its air: a thin bright line at the limb, a wide soft glow above.)
 if (h >= 0.0) {
  let thin = exp(-h / 2.6);
  let wide = exp(-h / 46.0);
  let dawn = mix(tint, vec3<f32>(0.55, 0.85, 1.0), 0.55);
  col = col + dawn * (wide * (0.1 + 0.42 * toward)) + mix(dawn, vec3<f32>(1.0), 0.7) * thin * (0.3 + 0.7 * toward);
  // (The sun itself, just clear of the limb.)
  let sp = c + sun * (R + 3.0);
  let sd = length(p - sp);
  col = col + vec3<f32>(1.0, 0.93, 0.82) * (exp(-sd / 9.0) * 1.2 + exp(-sd / 70.0) * 0.45 + exp(-abs(p.y - sp.y) / 1.4) * exp(-abs(p.x - sp.x) / 190.0) * 0.5);
 }
 if (h < aa) {
  // (The ground: night, with weather drifting over it and a little day
  // near where the sun is.)
  let g = d / R;
  let w = cz_fbm(vec2<f32>(g.x * 34.0 + t * 0.006, (g.y + 1.0) * 150.0) + seed);
  let w2 = cz_fbm(vec2<f32>(g.x * 90.0 - t * 0.004, (g.y + 1.0) * 380.0) + 5.0);
  let depth = clamp(-h / 90.0, 0.0, 1.0);
  var ground = mix(vec3<f32>(0.02, 0.035, 0.09), vec3<f32>(0.01, 0.014, 0.04), depth);
  let clouds = smoothstep(0.45, 0.8, w * 0.7 + w2 * 0.3);
  ground = ground + mix(tint, vec3<f32>(0.7, 0.85, 1.0), 0.6) * clouds * (0.05 + 0.5 * toward) * (1.0 - 0.6 * depth);
  ground = ground + mix(tint, vec3<f32>(0.55, 0.85, 1.0), 0.5) * exp(h / 14.0) * (0.12 + 0.6 * toward);
  col = mix(col, ground, smoothstep(aa, -aa, h));
 }

 return vec4<f32>(min(col, vec3<f32>(1.0)), 1.0);
}
]])

return M
