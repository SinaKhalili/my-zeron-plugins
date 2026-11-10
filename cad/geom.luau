-- A design (plain data, as the agent and the mouse write it) made solid:
-- its parameters and variables evaluated, each node's primitive made as
-- polygons, placed by its transforms and patterns, and combined in order.
--
-- A node: { type, name?, color?, mode?, if?, translate?, rotate?, scale?,
--   mirror?, repeat?, radial?, mirror_copy?, …its own fields, children? }

local csg = require("./csg")
local expr = require("./expr")

local M = {}

type Poly = csg.Poly
type Env = { [string]: number }
type Mat = { number } -- 3x4, row-major: { a, b, c, tx, d, e, f, ty, g, h, i, tz }

M.TYPES = {
	box = true, cylinder = true, sphere = true, torus = true, extrude = true, revolve = true,
	union = true, difference = true, intersection = true, group = true,
}

local IDENT: Mat = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 }

local function mul(a: Mat, b: Mat): Mat
	return {
		a[1] * b[1] + a[2] * b[5] + a[3] * b[9],
		a[1] * b[2] + a[2] * b[6] + a[3] * b[10],
		a[1] * b[3] + a[2] * b[7] + a[3] * b[11],
		a[1] * b[4] + a[2] * b[8] + a[3] * b[12] + a[4],
		a[5] * b[1] + a[6] * b[5] + a[7] * b[9],
		a[5] * b[2] + a[6] * b[6] + a[7] * b[10],
		a[5] * b[3] + a[6] * b[7] + a[7] * b[11],
		a[5] * b[4] + a[6] * b[8] + a[7] * b[12] + a[8],
		a[9] * b[1] + a[10] * b[5] + a[11] * b[9],
		a[9] * b[2] + a[10] * b[6] + a[11] * b[10],
		a[9] * b[3] + a[10] * b[7] + a[11] * b[11],
		a[9] * b[4] + a[10] * b[8] + a[11] * b[12] + a[12],
	}
end

local function translate(x: number, y: number, z: number): Mat
	return { 1, 0, 0, x, 0, 1, 0, y, 0, 0, 1, z }
end

local function rot_x(d: number): Mat
	local c, s = math.cos(math.rad(d)), math.sin(math.rad(d))
	return { 1, 0, 0, 0, 0, c, -s, 0, 0, s, c, 0 }
end
local function rot_y(d: number): Mat
	local c, s = math.cos(math.rad(d)), math.sin(math.rad(d))
	return { c, 0, s, 0, 0, 1, 0, 0, -s, 0, c, 0 }
end
local function rot_z(d: number): Mat
	local c, s = math.cos(math.rad(d)), math.sin(math.rad(d))
	return { c, -s, 0, 0, s, c, 0, 0, 0, 0, 1, 0 }
end

local function det(m: Mat): number
	return m[1] * (m[6] * m[11] - m[7] * m[10]) - m[2] * (m[5] * m[11] - m[7] * m[9]) + m[3] * (m[5] * m[10] - m[6] * m[9])
end

-- A mirror across the plane through the origin whose normal is (x, y, z).
local function mirror(x: number, y: number, z: number): Mat
	local l = math.sqrt(x * x + y * y + z * z)
	if l < 1e-12 then
		return IDENT
	end
	x, y, z = x / l, y / l, z / l
	return {
		1 - 2 * x * x, -2 * x * y, -2 * x * z, 0,
		-2 * x * y, 1 - 2 * y * y, -2 * y * z, 0,
		-2 * x * z, -2 * y * z, 1 - 2 * z * z, 0,
	}
end

local function apply(m: Mat, polys: { Poly }): { Poly }
	if m == IDENT then
		return polys
	end
	local flipped = det(m) < 0
	local out = table.create(#polys)
	for _, p in polys do
		local v = p.v
		local n = #v
		local nv = table.create(n)
		for i = 1, n do
			local q = v[if flipped then n - i + 1 else i]
			local x, y, z = q[1], q[2], q[3]
			nv[i] = {
				m[1] * x + m[2] * y + m[3] * z + m[4],
				m[5] * x + m[6] * y + m[7] * z + m[8],
				m[9] * x + m[10] * y + m[11] * z + m[12],
			}
		end
		local np = csg.poly(nv, p.part, p.color)
		if np then
			table.insert(out, np)
		end
		if #out % 128 == 0 then
			csg.pause()
		end
	end
	return out
end

-- Evaluation ----------------------------------------------------------------

local Eval = {}
Eval.__index = Eval

local function num(env: Env, v: any, default: number?, what: string): number
	if v == nil then
		if default == nil then
			error(`{what} is missing`, 0)
		end
		return default
	end
	local ok, r = pcall(expr.eval, v, env)
	if not ok then
		error(`{what}: {r}`, 0)
	end
	return r
end

local function vec3(env: Env, v: any, default: number, what: string): (number, number, number)
	if v == nil then
		return default, default, default
	end
	if type(v) ~= "table" then
		local n = num(env, v, default, what)
		return n, n, n
	end
	return num(env, v[1], default, what .. "[1]"), num(env, v[2], default, what .. "[2]"), num(env, v[3], default, what .. "[3]")
end

local function points(env: Env, v: any, what: string): { { number } }
	if type(v) ~= "table" or #v < 3 then
		error(`{what} needs 3 points or more`, 0)
	end
	local out = {}
	for i, p in v do
		if type(p) ~= "table" then
			error(`{what}[{i}] should be [x, y]`, 0)
		end
		table.insert(out, { num(env, p[1], nil, `{what}[{i}][1]`), num(env, p[2], nil, `{what}[{i}][2]`) })
	end
	return out
end

local function segments(env: Env, node: any, r: number): number
	if node.segments ~= nil then
		return math.clamp(math.floor(num(env, node.segments, 32, "segments")), 3, 256)
	end
	-- As OpenSCAD's $fa = 6, $fs = 1, a little finer.
	return math.clamp(math.ceil(math.min(360 / 6, r * 2 * math.pi / 0.8)), 8, 64)
end

-- Primitives ------------------------------------------------------------------

local function quad(out: { Poly }, a: { number }, b: { number }, c: { number }, d: { number }, part: number?, color: string?)
	local p = csg.poly({ a, b, c, d }, part, color)
	if p then
		table.insert(out, p)
	end
end

local function box(sx: number, sy: number, sz: number, center: boolean, part: number?, color: string?): { Poly }
	local x0, y0, z0 = 0, 0, 0
	if center then
		x0, y0, z0 = -sx / 2, -sy / 2, -sz / 2
	end
	local x1, y1, z1 = x0 + sx, y0 + sy, z0 + sz
	local out = {}
	quad(out, { x0, y0, z0 }, { x0, y1, z0 }, { x1, y1, z0 }, { x1, y0, z0 }, part, color) -- bottom
	quad(out, { x0, y0, z1 }, { x1, y0, z1 }, { x1, y1, z1 }, { x0, y1, z1 }, part, color) -- top
	quad(out, { x0, y0, z0 }, { x1, y0, z0 }, { x1, y0, z1 }, { x0, y0, z1 }, part, color) -- front
	quad(out, { x0, y1, z0 }, { x0, y1, z1 }, { x1, y1, z1 }, { x1, y1, z0 }, part, color) -- back
	quad(out, { x0, y0, z0 }, { x0, y0, z1 }, { x0, y1, z1 }, { x0, y1, z0 }, part, color) -- left
	quad(out, { x1, y0, z0 }, { x1, y1, z0 }, { x1, y1, z1 }, { x1, y0, z1 }, part, color) -- right
	return out
end

local function area2(pts: { { number } }): number
	local a = 0
	for i = 1, #pts do
		local p, q = pts[i], pts[(i % #pts) + 1]
		a += p[1] * q[2] - q[1] * p[2]
	end
	return a / 2
end

-- Ear clipping: a simple polygon (counter-clockwise) as triangles, or the
-- polygon itself when it's already convex.
local function triangulate(pts: { { number } }): { { number } }
	local n = #pts
	local convex = true
	for i = 1, n do
		local a, b, c = pts[i], pts[(i % n) + 1], pts[((i + 1) % n) + 1]
		if (b[1] - a[1]) * (c[2] - b[2]) - (b[2] - a[2]) * (c[1] - b[1]) < -1e-12 then
			convex = false
			break
		end
	end
	if convex then
		local all = {}
		for i = 1, n do
			all[i] = i
		end
		return { all }
	end
	local idx = {}
	for i = 1, n do
		idx[i] = i
	end
	local tris = {}
	local guard = 0
	while #idx > 3 and guard < n * n do
		guard += 1
		local m = #idx
		local found = false
		for i = 1, m do
			local ia, ib, ic = idx[((i - 2) % m) + 1], idx[i], idx[(i % m) + 1]
			local a, b, c = pts[ia], pts[ib], pts[ic]
			local cross = (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
			if cross > 1e-12 then
				local inside = false
				for _, j in idx do
					if j ~= ia and j ~= ib and j ~= ic then
						local p = pts[j]
						local d1 = (b[1] - a[1]) * (p[2] - a[2]) - (b[2] - a[2]) * (p[1] - a[1])
						local d2 = (c[1] - b[1]) * (p[2] - b[2]) - (c[2] - b[2]) * (p[1] - b[1])
						local d3 = (a[1] - c[1]) * (p[2] - c[2]) - (a[2] - c[2]) * (p[1] - c[1])
						if d1 >= 0 and d2 >= 0 and d3 >= 0 then
							inside = true
							break
						end
					end
				end
				if not inside then
					table.insert(tris, { ia, ib, ic })
					table.remove(idx, i)
					found = true
					break
				end
			end
		end
		if not found then
			-- (Self-touching: cut what's left as a fan.)
			break
		end
	end
	if #idx >= 3 then
		table.insert(tris, idx)
	end
	return tris
end

local function extrude(pts: { { number } }, h: number, part: number?, color: string?): { Poly }
	if area2(pts) < 0 then
		local r = {}
		for i = #pts, 1, -1 do
			table.insert(r, pts[i])
		end
		pts = r
	end
	local out = {}
	local n = #pts
	for _, tri in triangulate(pts) do
		local top, bottom = {}, {}
		for k = 1, #tri do
			local p = pts[tri[k]]
			table.insert(top, { p[1], p[2], h })
			local q = pts[tri[#tri - k + 1]]
			table.insert(bottom, { q[1], q[2], 0 })
		end
		local t, b = csg.poly(top, part, color), csg.poly(bottom, part, color)
		if t then
			table.insert(out, t)
		end
		if b then
			table.insert(out, b)
		end
	end
	for i = 1, n do
		local a, b = pts[i], pts[(i % n) + 1]
		quad(out, { a[1], a[2], 0 }, { b[1], b[2], 0 }, { b[1], b[2], h }, { a[1], a[2], h }, part, color)
	end
	return out
end

local function circle_points(r: number, seg: number): { { number } }
	local out = {}
	for i = 0, seg - 1 do
		local a = i / seg * 2 * math.pi
		table.insert(out, { r * math.cos(a), r * math.sin(a) })
	end
	return out
end

local function rounded_rect(sx: number, sy: number, r: number, center: boolean): { { number } }
	r = math.clamp(r, 0, math.min(sx, sy) / 2 - 1e-6)
	local x0, y0 = if center then -sx / 2 else 0, if center then -sy / 2 else 0
	local corners = {
		{ x0 + sx - r, y0 + r, -90 },
		{ x0 + sx - r, y0 + sy - r, 0 },
		{ x0 + r, y0 + sy - r, 90 },
		{ x0 + r, y0 + r, 180 },
	}
	local seg = math.clamp(math.ceil(r * math.pi / 2 / 0.8), 2, 12)
	local out = {}
	for _, c in corners do
		for k = 0, seg do
			local a = math.rad(c[3] + k / seg * 90)
			table.insert(out, { c[1] + r * math.cos(a), c[2] + r * math.sin(a) })
		end
	end
	return out
end

local function cylinder(r1: number, r2: number, h: number, seg: number, center: boolean, part: number?, color: string?): { Poly }
	local z0 = if center then -h / 2 else 0
	local z1 = z0 + h
	local out = {}
	local bottom, top = {}, {}
	for i = 0, seg - 1 do
		local a0 = i / seg * 2 * math.pi
		local a1 = (i + 1) / seg * 2 * math.pi
		local c0, s0, c1, s1 = math.cos(a0), math.sin(a0), math.cos(a1), math.sin(a1)
		local p = csg.poly({ { r1 * c0, r1 * s0, z0 }, { r1 * c1, r1 * s1, z0 }, { r2 * c1, r2 * s1, z1 }, { r2 * c0, r2 * s0, z1 } }, part, color)
		if p then
			table.insert(out, p)
		end
		table.insert(top, { r2 * c0, r2 * s0, z1 })
		table.insert(bottom, 1, { r1 * c0, r1 * s0, z0 })
	end
	if r1 > 1e-9 then
		local p = csg.poly(bottom, part, color)
		if p then
			table.insert(out, p)
		end
	end
	if r2 > 1e-9 then
		local p = csg.poly(top, part, color)
		if p then
			table.insert(out, p)
		end
	end
	return out
end

local function sphere(r: number, seg: number, part: number?, color: string?): { Poly }
	local stacks = math.max(4, seg // 2)
	local out = {}
	local function at(i: number, j: number): { number }
		local th = i / seg * 2 * math.pi
		local ph = j / stacks * math.pi
		return { r * math.sin(ph) * math.cos(th), r * math.sin(ph) * math.sin(th), r * math.cos(ph) }
	end
	for i = 0, seg - 1 do
		for j = 0, stacks - 1 do
			local v = {}
			table.insert(v, at(i, j))
			if j > 0 then
				table.insert(v, at(i + 1, j))
			end
			-- (Counter-clockwise from outside: down the meridian, then across.)
			if j < stacks - 1 then
				table.insert(v, at(i + 1, j + 1))
			end
			table.insert(v, at(i, j + 1))
			-- The order above runs clockwise from outside; turn it.
			local rv = {}
			for k = #v, 1, -1 do
				table.insert(rv, v[k])
			end
			local p = csg.poly(rv, part, color)
			if p then
				table.insert(out, p)
			end
		end
	end
	return out
end

-- A profile in (r, z), turned about the Z axis by `angle` degrees.
local function revolve(pts: { { number } }, angle: number, seg: number, part: number?, color: string?): { Poly }
	if area2(pts) < 0 then
		local r = {}
		for i = #pts, 1, -1 do
			table.insert(r, pts[i])
		end
		pts = r
	end
	local full = angle >= 359.999
	angle = math.clamp(angle, 1, 360)
	local steps = math.max(3, math.ceil(seg * angle / 360))
	local out = {}
	local n = #pts
	local function at(p: { number }, k: number): { number }
		local a = math.rad(angle * k / steps)
		return { p[1] * math.cos(a), p[1] * math.sin(a), p[2] }
	end
	for k = 0, steps - 1 do
		for i = 1, n do
			local p, q = pts[i], pts[(i % n) + 1]
			local A, B, C, D = at(p, k), at(q, k), at(q, k + 1), at(p, k + 1)
			local poly = csg.poly({ A, D, C, B }, part, color)
			if poly then
				table.insert(out, poly)
			end
		end
	end
	if not full then
		for _, tri in triangulate(pts) do
			local start, finish = {}, {}
			for k = 1, #tri do
				table.insert(start, at(pts[tri[k]], 0))
				table.insert(finish, at(pts[tri[#tri - k + 1]], steps))
			end
			local s, f = csg.poly(start, part, color), csg.poly(finish, part, color)
			if s then
				table.insert(out, s)
			end
			if f then
				table.insert(out, f)
			end
		end
	end
	return out
end

local function torus(R: number, r: number, seg: number, seg2: number, part: number?, color: string?): { Poly }
	local profile = {}
	for i = 0, seg2 - 1 do
		local a = i / seg2 * 2 * math.pi
		table.insert(profile, { R + r * math.cos(a), r * math.sin(a) })
	end
	return revolve(profile, 360, seg, part, color)
end

-- Nodes -----------------------------------------------------------------------

export type Part = { id: number, path: string, name: string?, type: string, node: any, mode: string? }

export type Result = { polys: { Poly }, parts: { Part }, warnings: { string } }

local function child_path(path: string, i: number): string
	return `{path}.children.{i}`
end

-- The node's own placement: translate · rotate · scale · mirror.
local function placement(env: Env, node: any, path: string): Mat
	local m = IDENT
	if node.translate ~= nil then
		local x, y, z = vec3(env, node.translate, 0, `{path}.translate`)
		m = mul(m, translate(x, y, z))
	end
	if node.rotate ~= nil then
		local x, y, z = vec3(env, node.rotate, 0, `{path}.rotate`)
		m = mul(m, mul(rot_z(z), mul(rot_y(y), rot_x(x))))
	end
	if node.scale ~= nil then
		local x, y, z = vec3(env, node.scale, 1, `{path}.scale`)
		m = mul(m, { x, 0, 0, 0, 0, y, 0, 0, 0, 0, z, 0 })
	end
	if node.mirror ~= nil then
		local x, y, z = vec3(env, node.mirror, 0, `{path}.mirror`)
		m = mul(m, mirror(x, y, z))
	end
	return m
end

local solid: (env: Env, node: any, path: string, color: string?, out: Result) -> { Poly }

local function combine(env: Env, node: any, path: string, color: string?, out: Result): { Poly }
	local kids = node.children
	if type(kids) ~= "table" then
		error(`{path}.children should be a list`, 0)
	end
	local t = node.type
	if t == "difference" then
		local base = {}
		local cuts = {}
		for i, c in kids do
			local s = solid(env, c, child_path(path, i), color, out)
			if i == 1 then
				base = s
			else
				table.insert(cuts, s)
			end
		end
		return csg.subtract(base, csg.union_all(cuts))
	elseif t == "intersection" then
		local acc: { Poly }? = nil
		for i, c in kids do
			local s = solid(env, c, child_path(path, i), color, out)
			acc = if acc == nil then s else csg.intersect(acc, s)
		end
		return acc or {}
	end
	-- union, group: in order, each child's own mode (add, cut, intersect)
	-- applied to what came before, as a feature list.
	return M.features(env, kids, path .. ".children", color, out)
end

local function primitive(env: Env, node: any, path: string, color: string?, out: Result): { Poly }
	local t = node.type
	local part = #out.parts + 1
	table.insert(out.parts, { id = part, path = path, name = node.name, type = t, node = node, mode = node.mode })
	local center = node.center == true or node.center == 1
	if t == "box" then
		local x, y, z = vec3(env, node.size, 10, `{path}.size`)
		if x <= 0 or y <= 0 or z <= 0 then
			error(`{path}: a box's size must be above 0`, 0)
		end
		local r = if node.radius ~= nil then num(env, node.radius, 0, `{path}.radius`) else 0
		if r > 1e-6 then
			local polys = extrude(rounded_rect(x, y, r, center), z, part, color)
			if center then
				polys = apply(translate(0, 0, -z / 2), polys)
			end
			return polys
		end
		return box(x, y, z, center, part, color)
	elseif t == "cylinder" then
		local h = num(env, node.h, 10, `{path}.h`)
		local r = if node.d ~= nil then num(env, node.d, nil, `{path}.d`) / 2 else num(env, node.r, 5, `{path}.r`)
		local r1 = if node.d1 ~= nil then num(env, node.d1, nil, `{path}.d1`) / 2 elseif node.r1 ~= nil then num(env, node.r1, nil, `{path}.r1`) else r
		local r2 = if node.d2 ~= nil then num(env, node.d2, nil, `{path}.d2`) / 2 elseif node.r2 ~= nil then num(env, node.r2, nil, `{path}.r2`) else r
		if h <= 0 or (r1 <= 0 and r2 <= 0) or r1 < 0 or r2 < 0 then
			error(`{path}: a cylinder needs h > 0 and a radius > 0`, 0)
		end
		return cylinder(r1, r2, h, segments(env, node, math.max(r1, r2)), center, part, color)
	elseif t == "sphere" then
		local r = if node.d ~= nil then num(env, node.d, nil, `{path}.d`) / 2 else num(env, node.r, 5, `{path}.r`)
		if r <= 0 then
			error(`{path}: a sphere's radius must be above 0`, 0)
		end
		return sphere(r, segments(env, node, r), part, color)
	elseif t == "torus" then
		local R = num(env, node.R, 10, `{path}.R`)
		local r = num(env, node.r, 2, `{path}.r`)
		if r <= 0 or R <= r then
			error(`{path}: a torus needs R > r > 0`, 0)
		end
		local seg = segments(env, node, R)
		return torus(R, r, seg, math.clamp(math.ceil(segments(env, {}, r) * 0.75), 8, 32), part, color)
	elseif t == "extrude" then
		local h = num(env, node.h, 10, `{path}.h`)
		if h <= 0 then
			error(`{path}: h must be above 0`, 0)
		end
		local pts
		if node.circle ~= nil then
			local r = num(env, node.circle, nil, `{path}.circle`)
			pts = circle_points(r, segments(env, node, r))
		else
			pts = points(env, node.points, `{path}.points`)
		end
		local polys = extrude(pts, h, part, color)
		if center then
			polys = apply(translate(0, 0, -h / 2), polys)
		end
		return polys
	elseif t == "revolve" then
		local pts = points(env, node.points, `{path}.points`)
		for i, p in pts do
			if p[1] < -1e-9 then
				error(`{path}.points[{i}]: a profile stays at r ≥ 0`, 0)
			end
		end
		local angle = num(env, node.angle, 360, `{path}.angle`)
		local maxr = 0
		for _, p in pts do
			maxr = math.max(maxr, p[1])
		end
		return revolve(pts, angle, segments(env, node, maxr), part, color)
	end
	error(`{path}: unknown type "{tostring(t)}"`, 0)
end

solid = function(env: Env, node: any, path: string, color: string?, out: Result): { Poly }
	if type(node) ~= "table" then
		error(`{path} should be an object`, 0)
	end
	local t = node.type
	if not M.TYPES[t] then
		error(`{path}: unknown type "{tostring(t)}" (box, cylinder, sphere, torus, extrude, revolve, union, difference, intersection, group)`, 0)
	end
	local c = if type(node.color) == "string" then node.color else color
	local polys
	if t == "union" or t == "group" or t == "difference" or t == "intersection" then
		polys = combine(env, node, path, c, out)
	else
		polys = primitive(env, node, path, c, out)
	end
	csg.pause()
	polys = apply(placement(env, node, path), polys)
	-- Patterns: copies of the placed node, as one.
	if node.mirror_copy ~= nil then
		local x, y, z = vec3(env, node.mirror_copy, 0, `{path}.mirror_copy`)
		polys = csg.union(polys, apply(mirror(x, y, z), polys))
	end
	if type(node["repeat"]) == "table" then
		local rp = node["repeat"]
		local n = math.clamp(math.floor(num(env, rp.count, 2, `{path}.repeat.count`)), 1, 200)
		local dx, dy, dz = vec3(env, rp.offset, 0, `{path}.repeat.offset`)
		local copies = {}
		for i = 0, n - 1 do
			table.insert(copies, apply(if i == 0 then IDENT else translate(dx * i, dy * i, dz * i), polys))
		end
		polys = csg.union_all(copies)
	end
	if type(node.radial) == "table" then
		local rd = node.radial
		local n = math.clamp(math.floor(num(env, rd.count, 6, `{path}.radial.count`)), 1, 360)
		local total = num(env, rd.angle, 360, `{path}.radial.angle`)
		local step = if math.abs(total) >= 359.999 then total / n else total / math.max(1, n - 1)
		local axis = rd.axis or "z"
		local cx, cy, cz = vec3(env, rd.center, 0, `{path}.radial.center`)
		local copies = {}
		for i = 0, n - 1 do
			local r = if axis == "x" then rot_x(step * i) elseif axis == "y" then rot_y(step * i) else rot_z(step * i)
			local m = mul(translate(cx, cy, cz), mul(r, translate(-cx, -cy, -cz)))
			table.insert(copies, apply(if i == 0 then IDENT else m, polys))
		end
		polys = csg.union_all(copies)
	end
	return polys
end

-- A list of nodes in order: each added (mode "add", the default), cut from
-- what came before ("cut"), or kept only where it overlaps it ("intersect").
function M.features(env: Env, list: any, path: string, color: string?, out: Result): { Poly }
	if type(list) ~= "table" then
		error(`{path} should be a list`, 0)
	end
	local acc: { Poly } = {}
	local adds: { { Poly } } = {}
	local function flush()
		if #adds > 0 then
			table.insert(adds, 1, acc)
			acc = csg.union_all(adds)
			adds = {}
		end
	end
	for i, node in list do
		local p = `{path}.{i}`
		local skip = false
		if type(node) == "table" and node["if"] ~= nil then
			skip = num(env, node["if"], 1, `{p}.if`) == 0
		end
		if type(node) == "table" and node.hidden == true then
			skip = true
		end
		if not skip then
			local s = solid(env, node, p, color, out)
			local mode = if type(node) == "table" then node.mode else nil
			if mode == "cut" then
				flush()
				acc = csg.subtract(acc, s)
			elseif mode == "intersect" then
				flush()
				acc = csg.intersect(acc, s)
			else
				-- (Adds run together are merged at once, pairwise.)
				table.insert(adds, s)
			end
		end
	end
	flush()
	return acc
end

-- The values a design's numbers see: each parameter (the person's value,
-- else its own), then each variable in order.
function M.environment(design: any, values: { [string]: any }?): (Env, { string })
	local env: Env = {}
	local warnings = {}
	for i, p in (if type(design.params) == "table" then design.params else {}) :: { any } do
		if type(p) == "table" and type(p.id) == "string" then
			local v = if values then values[p.id] else nil
			if v == nil then
				v = p.value
			end
			local ok, r = pcall(expr.eval, v, env)
			if ok then
				env[p.id] = r
			else
				table.insert(warnings, `params[{i}] ({p.id}): {r}`)
				env[p.id] = 0
			end
		end
	end
	for i, v in (if type(design.vars) == "table" then design.vars else {}) :: { any } do
		if type(v) == "table" and type(v.id) == "string" then
			local ok, r = pcall(expr.eval, v.value, env)
			if ok then
				env[v.id] = r
			else
				error(`vars[{i}] ({v.id}): {r}`, 0)
			end
		end
	end
	return env, warnings
end

-- The whole design: { polys, parts, warnings }. Errors say where.
function M.build(design: any, values: { [string]: any }?): Result
	if type(design) ~= "table" then
		error("a design is an object", 0)
	end
	local env, warnings = M.environment(design, values)
	local out: Result = { polys = {}, parts = {}, warnings = warnings }
	out.polys = M.features(env, design.body or {}, "body", nil, out)
	return out
end

-- A box between two corners, as polygons (a section's cutter).
function M.cuboid(x0: number, y0: number, z0: number, x1: number, y1: number, z1: number, part: number?, color: string?): { Poly }
	return apply(translate(x0, y0, z0), box(x1 - x0, y1 - y0, z1 - z0, false, part, color))
end

-- The design as separate pieces, for an exploded view: each top-level
-- feature that adds (a box, a group…) as a solid of its own, less every
-- cut that comes after it and kept to every intersect after it, so each
-- piece keeps its holes. { { polys, name, path } }, and the parts.
function M.pieces(design: any, values: { [string]: any }?): ({ any }, { Part })
	local env = M.environment(design, values)
	local out: Result = { polys = {}, parts = {}, warnings = {} }
	local list = design.body or {}
	local feats: { any } = {}
	for i, node in list do
		local p = `body.{i}`
		local skip = type(node) ~= "table" or node.hidden == true
		if not skip and node["if"] ~= nil then
			skip = num(env, node["if"], 1, `{p}.if`) == 0
		end
		if not skip then
			table.insert(feats, { polys = solid(env, node, p, nil, out), mode = node.mode or "add", name = node.name or node.type, path = p })
		end
	end
	local pieces = {}
	for i, f in feats do
		if f.mode ~= "cut" and f.mode ~= "intersect" then
			local s = f.polys
			for j = i + 1, #feats do
				local g = feats[j]
				if g.mode == "cut" then
					s = csg.subtract(s, g.polys)
				elseif g.mode == "intersect" then
					s = csg.intersect(s, g.polys)
				end
			end
			if #s > 0 then
				table.insert(pieces, { polys = s, name = f.name, path = f.path })
			end
		end
	end
	return pieces, out.parts
end

-- The node at a path ("body.2.children.1"), and its parent list and index.
function M.at(design: any, path: string): (any, any, number?)
	local cur: any = design
	local parent: any, index: number? = nil, nil
	for key in string.gmatch(path, "[^%.]+") do
		local n = tonumber(key)
		if cur == nil then
			return nil, nil, nil
		end
		if n then
			parent, index = cur, n
			cur = cur[n]
		else
			cur = cur[key]
		end
	end
	return cur, parent, index
end

return M
