-- Solids for Cosmos' rockets, as `ui.mesh` takes its own triangles: turned
-- profiles, wedges, boxes and struts, and several of them as one mesh. Y is
-- up; an angle `a` about it points along (cos a, 0, sin a).

local M = {}

export type Ring = { number } -- { r, y } or { r, y, red, green, blue, alpha }
export type Geometry = any

-- A profile turned about Y, from angle `a0` to `a1` (radians) in `n` steps:
-- smooth, its normals from the profile's own slope. `profile` runs bottom to
-- top (or outward, for a disc facing down); `inside` faces it the other way.
function M.lathe(profile: { Ring }, n: number, a0: number?, a1: number?, inside: boolean?): Geometry
	local from, to = a0 or 0, a1 or math.pi * 2
	local pos, nor, idx, col = {}, {}, {}, {}
	local tinted = #profile[1] > 2
	local rows = #profile
	for i = 1, rows do
		local p = profile[i]
		local a, b = profile[math.max(i - 1, 1)], profile[math.min(i + 1, rows)]
		local dr, dy = b[1] - a[1], b[2] - a[2]
		local l = math.sqrt(dr * dr + dy * dy)
		local nr, ny = dy / l, -dr / l
		if inside then
			nr, ny = -nr, -ny
		end
		for j = 0, n do
			local ang = from + (to - from) * j / n
			local c, s = math.cos(ang), math.sin(ang)
			table.insert(pos, p[1] * c)
			table.insert(pos, p[2])
			table.insert(pos, p[1] * s)
			table.insert(nor, nr * c)
			table.insert(nor, ny)
			table.insert(nor, nr * s)
			if tinted then
				table.insert(col, p[3])
				table.insert(col, p[4])
				table.insert(col, p[5])
				table.insert(col, p[6] or 1)
			end
		end
	end
	local w = n + 1
	for i = 0, rows - 2 do
		for j = 0, n - 1 do
			local a, b, c, d = i * w + j + 1, (i + 1) * w + j + 1, (i + 1) * w + j + 2, i * w + j + 2
			if inside then
				b, d = d, b
			end
			table.insert(idx, a)
			table.insert(idx, b)
			table.insert(idx, c)
			table.insert(idx, a)
			table.insert(idx, c)
			table.insert(idx, d)
		end
	end
	return { positions = pos, normals = nor, indices = idx, colors = if tinted then col else nil }
end

-- Flat triangles of a convex solid, each turned away from its middle.
local function solid(mid: { number }): ({ number }, (a: { number }, b: { number }, c: { number }) -> ())
	local pos = {}
	return pos, function(a, b, c)
		local ux, uy, uz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
		local vx, vy, vz = c[1] - a[1], c[2] - a[2], c[3] - a[3]
		local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
		if nx * (a[1] - mid[1]) + ny * (a[2] - mid[2]) + nz * (a[3] - mid[3]) < 0 then
			b, c = c, b
		end
		for _, p in { a, b, c } do
			table.insert(pos, p[1])
			table.insert(pos, p[2])
			table.insert(pos, p[3])
		end
	end
end

-- A fin or a wing: a convex outline in the XY plane ({ x, y }), a wedge
-- `root` thick (half of it) at its least x and `tip` at its most, its
-- middle at `z`.
function M.wedge(outline: { { number } }, root: number, tip: number, z: number?): Geometry
	local x0, x1, cx, cy = math.huge, -math.huge, 0, 0
	for _, p in outline do
		x0, x1 = math.min(x0, p[1]), math.max(x1, p[1])
		cx, cy = cx + p[1] / #outline, cy + p[2] / #outline
	end
	local z0 = z or 0
	local function at(p: { number }, side: number): { number }
		return { p[1], p[2], z0 + side * (root + (tip - root) * (p[1] - x0) / (x1 - x0)) }
	end
	local pos, tri = solid({ cx, cy, z0 })
	local n = #outline
	for i = 2, n - 1 do
		tri(at(outline[1], 1), at(outline[i], 1), at(outline[i + 1], 1))
		tri(at(outline[1], -1), at(outline[i], -1), at(outline[i + 1], -1))
	end
	for i = 1, n do
		local a, b = outline[i], outline[i % n + 1]
		tri(at(a, 1), at(b, 1), at(b, -1))
		tri(at(a, 1), at(b, -1), at(a, -1))
	end
	return { positions = pos, flat = true }
end

-- A box between two corners.
function M.box(x0: number, y0: number, z0: number, x1: number, y1: number, z1: number): Geometry
	local pos, tri = solid({ (x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2 })
	local function quad(a: { number }, b: { number }, c: { number }, d: { number })
		tri(a, b, c)
		tri(a, c, d)
	end
	quad({ x0, y0, z0 }, { x1, y0, z0 }, { x1, y1, z0 }, { x0, y1, z0 })
	quad({ x0, y0, z1 }, { x1, y0, z1 }, { x1, y1, z1 }, { x0, y1, z1 })
	quad({ x0, y0, z0 }, { x1, y0, z0 }, { x1, y0, z1 }, { x0, y0, z1 })
	quad({ x0, y1, z0 }, { x1, y1, z0 }, { x1, y1, z1 }, { x0, y1, z1 })
	quad({ x0, y0, z0 }, { x0, y1, z0 }, { x0, y1, z1 }, { x0, y0, z1 })
	quad({ x1, y0, z0 }, { x1, y1, z0 }, { x1, y1, z1 }, { x1, y0, z1 })
	return { positions = pos, flat = true }
end

-- A square strut from `a` to `b` (never along X), `r` from its middle to a
-- corner.
function M.strut(a: { number }, b: { number }, r: number): Geometry
	local dx, dy, dz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
	local l = math.sqrt(dx * dx + dy * dy + dz * dz)
	dx, dy, dz = dx / l, dy / l, dz / l
	local ux, uy, uz = 0, dz, -dy
	local ul = math.sqrt(uy * uy + uz * uz)
	uy, uz = uy / ul, uz / ul
	local wx, wy, wz = dy * uz - dz * uy, dz * ux - dx * uz, dx * uy - dy * ux
	local function corner(p: { number }, k: number): { number }
		local c, s = math.cos(k * math.pi / 2) * r, math.sin(k * math.pi / 2) * r
		return { p[1] + ux * c + wx * s, p[2] + uy * c + wy * s, p[3] + uz * c + wz * s }
	end
	local pos, tri = solid({ (a[1] + b[1]) / 2, (a[2] + b[2]) / 2, (a[3] + b[3]) / 2 })
	for k = 0, 3 do
		tri(corner(a, k), corner(b, k), corner(b, k + 1))
		tri(corner(a, k), corner(b, k + 1), corner(a, k + 1))
	end
	return { positions = pos, flat = true }
end

-- A turned solid leaning: each point moved `lean` along X for every unit it
-- stands over `foot`.
function M.leaning(g: Geometry, lean: number, foot: number): Geometry
	local pos = table.clone(g.positions)
	for i = 1, #pos, 3 do
		pos[i] += lean * (pos[i + 1] - foot)
	end
	return { positions = pos, normals = g.normals, indices = g.indices, colors = g.colors }
end

-- Several geometries as one mesh: each { geometry, turned by (radians, about
-- Y: its +X to the angle), then moved by x, z }. All smooth or all flat.
function M.merge(list: { { any } }): Geometry
	local pos, nor, idx, col = {}, {}, {}, {}
	local flat, tinted = false, false
	for _, item in list do
		local g, turn, dx, dz = item[1], item[2] or 0, item[3] or 0, item[4] or 0
		local c, s = math.cos(turn), math.sin(turn)
		local base = #pos / 3
		for i = 1, #g.positions, 3 do
			local x, z = g.positions[i], g.positions[i + 2]
			table.insert(pos, x * c - z * s + dx)
			table.insert(pos, g.positions[i + 1])
			table.insert(pos, x * s + z * c + dz)
		end
		if g.normals then
			for i = 1, #g.normals, 3 do
				local x, z = g.normals[i], g.normals[i + 2]
				table.insert(nor, x * c - z * s)
				table.insert(nor, g.normals[i + 1])
				table.insert(nor, x * s + z * c)
			end
			for _, v in g.indices do
				table.insert(idx, base + v)
			end
		else
			flat = true
		end
		if g.colors then
			tinted = true
			table.move(g.colors, 1, #g.colors, #col + 1, col)
		end
	end
	if flat then
		return { positions = pos, flat = true }
	end
	return { positions = pos, normals = nor, indices = idx, colors = if tinted then col else nil }
end

-- Where `count` things stand in a ring `r` from the middle, the first at
-- angle `a0`: { x, z, angle } each.
function M.ring(count: number, r: number, a0: number?): { { number } }
	local out = {}
	for k = 0, count - 1 do
		local a = (a0 or 0) + k * 2 * math.pi / count
		table.insert(out, { r * math.cos(a), r * math.sin(a), a })
	end
	return out
end

return M
