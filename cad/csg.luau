-- Constructive solid geometry on polygon soups, by BSP trees (after Evan
-- Wallace's csg.js, MIT). A solid is a list of convex polygons, each
-- { v = { {x, y, z}, … }, nx, ny, nz, w, part, color }, wound counter-
-- clockwise seen from outside. Every walk is iterative (no deep recursion)
-- and calls `pause()` now and then, so a long boolean is cut into slices
-- that each fit a plugin call's time budget.

local M = {}

local EPS = 1e-5
local COPLANAR, FRONT, BACK, SPANNING = 0, 1, 2, 3

-- Set by the caller: called often; yields when the slice has run long.
M.pause = function() end

export type Vec = { number }
export type Poly = { v: { Vec }, nx: number, ny: number, nz: number, w: number, part: number?, color: string? }

-- A polygon's plane from its vertices (Newell's method: robust for any
-- convex polygon, even with near-collinear corners). Nil if degenerate.
function M.poly(v: { Vec }, part: number?, color: string?): Poly?
	-- Drop repeated corners.
	local clean: { Vec } = {}
	local n = #v
	for i = 1, n do
		local a, b = v[i], v[(i % n) + 1]
		local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
		if dx * dx + dy * dy + dz * dz > 1e-14 then
			table.insert(clean, a)
		end
	end
	if #clean < 3 then
		return nil
	end
	local nx, ny, nz = 0, 0, 0
	local m = #clean
	for i = 1, m do
		local a, b = clean[i], clean[(i % m) + 1]
		nx += (a[2] - b[2]) * (a[3] + b[3])
		ny += (a[3] - b[3]) * (a[1] + b[1])
		nz += (a[1] - b[1]) * (a[2] + b[2])
	end
	local len = math.sqrt(nx * nx + ny * ny + nz * nz)
	if len < 1e-12 then
		return nil
	end
	nx, ny, nz = nx / len, ny / len, nz / len
	local p = clean[1]
	return { v = clean, nx = nx, ny = ny, nz = nz, w = nx * p[1] + ny * p[2] + nz * p[3], part = part, color = color }
end

local function copy(p: Poly): Poly
	return { v = p.v, nx = p.nx, ny = p.ny, nz = p.nz, w = p.w, part = p.part, color = p.color }
end

local function flip(p: Poly)
	local v, n = p.v, #p.v
	local r = table.create(n)
	for i = 1, n do
		r[i] = v[n - i + 1]
	end
	p.v = r
	p.nx, p.ny, p.nz, p.w = -p.nx, -p.ny, -p.nz, -p.w
end

-- Splits `p` by the plane (nx, ny, nz, w) into the four lists.
local function split(nx: number, ny: number, nz: number, w: number, p: Poly, cf: { Poly }, cb: { Poly }, f: { Poly }, b: { Poly })
	local v = p.v
	local n = #v
	local kind = 0
	local types = table.create(n)
	for i = 1, n do
		local q = v[i]
		local t = nx * q[1] + ny * q[2] + nz * q[3] - w
		local ty = if t < -EPS then BACK elseif t > EPS then FRONT else COPLANAR
		kind = bit32.bor(kind, ty)
		types[i] = ty
	end
	if kind == COPLANAR then
		if nx * p.nx + ny * p.ny + nz * p.nz > 0 then
			table.insert(cf, p)
		else
			table.insert(cb, p)
		end
	elseif kind == FRONT then
		table.insert(f, p)
	elseif kind == BACK then
		table.insert(b, p)
	else
		local fv: { Vec }, bv: { Vec } = {}, {}
		for i = 1, n do
			local j = (i % n) + 1
			local ti, tj = types[i], types[j]
			local vi, vj = v[i], v[j]
			if ti ~= BACK then
				table.insert(fv, vi)
			end
			if ti ~= FRONT then
				table.insert(bv, vi)
			end
			if bit32.bor(ti, tj) == SPANNING then
				local di = nx * vi[1] + ny * vi[2] + nz * vi[3]
				local dj = nx * vj[1] + ny * vj[2] + nz * vj[3]
				local t = (w - di) / (dj - di)
				local q = { vi[1] + (vj[1] - vi[1]) * t, vi[2] + (vj[2] - vi[2]) * t, vi[3] + (vj[3] - vi[3]) * t }
				table.insert(fv, q)
				table.insert(bv, q)
			end
		end
		if #fv >= 3 then
			table.insert(f, { v = fv, nx = p.nx, ny = p.ny, nz = p.nz, w = p.w, part = p.part, color = p.color })
		end
		if #bv >= 3 then
			table.insert(b, { v = bv, nx = p.nx, ny = p.ny, nz = p.nz, w = p.w, part = p.part, color = p.color })
		end
	end
end

type Node = { plane: { number }?, front: Node?, back: Node?, polys: { Poly } }

local function node(): Node
	return { plane = nil, front = nil, back = nil, polys = {} }
end

local function build(root: Node, polys: { Poly })
	local stack: { any } = { root, polys }
	while #stack > 0 do
		local list = table.remove(stack) :: { Poly }
		local nd = table.remove(stack) :: Node
		if #list > 0 then
			if not nd.plane then
				-- (The middle polygon's plane: a better split, on average,
				-- than the first's for the ordered lists primitives make.)
				local p = list[(#list // 2) + 1]
				nd.plane = { p.nx, p.ny, p.nz, p.w }
			end
			local pl = nd.plane :: { number }
			local f, b = {}, {}
			for i, p in list do
				split(pl[1], pl[2], pl[3], pl[4], p, nd.polys, nd.polys, f, b)
				if i % 64 == 0 then
					M.pause()
				end
			end
			M.pause()
			if #f > 0 then
				if not nd.front then
					nd.front = node()
				end
				table.insert(stack, nd.front)
				table.insert(stack, f)
			end
			if #b > 0 then
				if not nd.back then
					nd.back = node()
				end
				table.insert(stack, nd.back)
				table.insert(stack, b)
			end
		end
	end
end

local function each(root: Node, fn: (Node) -> ())
	local stack = { root }
	while #stack > 0 do
		local nd = table.remove(stack) :: Node
		fn(nd)
		if nd.front then
			table.insert(stack, nd.front)
		end
		if nd.back then
			table.insert(stack, nd.back)
		end
	end
end

local function invert(root: Node)
	each(root, function(nd)
		for _, p in nd.polys do
			flip(p)
		end
		if nd.plane then
			local pl = nd.plane
			nd.plane = { -pl[1], -pl[2], -pl[3], -pl[4] }
		end
		nd.front, nd.back = nd.back, nd.front
		M.pause()
	end)
end

-- The parts of `polys` outside the solid `root` describes.
local function clip_polys(root: Node, polys: { Poly }): { Poly }
	local out: { Poly } = {}
	local stack: { any } = { root, polys }
	local count = 0
	while #stack > 0 do
		local list = table.remove(stack) :: { Poly }
		local nd = table.remove(stack) :: Node
		if not nd.plane then
			for _, p in list do
				table.insert(out, p)
			end
		else
			local pl = nd.plane
			local f, b = {}, {}
			for _, p in list do
				split(pl[1], pl[2], pl[3], pl[4], p, f, b, f, b)
				count += 1
				if count % 64 == 0 then
					M.pause()
				end
			end
			if nd.front then
				table.insert(stack, nd.front)
				table.insert(stack, f)
			else
				for _, p in f do
					table.insert(out, p)
				end
			end
			if nd.back then
				table.insert(stack, nd.back)
				table.insert(stack, b)
			end
		end
	end
	return out
end

local function clip_to(a: Node, b: Node)
	each(a, function(nd)
		nd.polys = clip_polys(b, nd.polys)
	end)
end

local function all(root: Node): { Poly }
	local out: { Poly } = {}
	each(root, function(nd)
		for _, p in nd.polys do
			table.insert(out, p)
		end
	end)
	return out
end

local function tree(polys: { Poly }): Node
	local cloned = table.create(#polys)
	for i, p in polys do
		cloned[i] = copy(p)
	end
	local nd = node()
	build(nd, cloned)
	return nd
end

-- Axis-aligned bounds of a solid: { minx, miny, minz, maxx, maxy, maxz }.
function M.bounds(polys: { Poly }): { number }?
	if #polys == 0 then
		return nil
	end
	local a, b, c = math.huge, math.huge, math.huge
	local d, e, f = -math.huge, -math.huge, -math.huge
	for _, p in polys do
		for _, q in p.v do
			local x, y, z = q[1], q[2], q[3]
			if x < a then a = x end
			if y < b then b = y end
			if z < c then c = z end
			if x > d then d = x end
			if y > e then e = y end
			if z > f then f = z end
		end
	end
	return { a, b, c, d, e, f }
end

local function apart(x: { number }?, y: { number }?): boolean
	if not x or not y then
		return true
	end
	local m = 1e-4
	return x[4] < y[1] - m or y[4] < x[1] - m or x[5] < y[2] - m or y[5] < x[2] - m or x[6] < y[3] - m or y[6] < x[3] - m
end

local function concat(a: { Poly }, b: { Poly }): { Poly }
	local out = table.create(#a + #b)
	for _, p in a do
		table.insert(out, p)
	end
	for _, p in b do
		table.insert(out, p)
	end
	return out
end

function M.union(a: { Poly }, b: { Poly }): { Poly }
	if #a == 0 then
		return b
	elseif #b == 0 then
		return a
	end
	if apart(M.bounds(a), M.bounds(b)) then
		return concat(a, b)
	end
	local ta, tb = tree(a), tree(b)
	clip_to(ta, tb)
	clip_to(tb, ta)
	invert(tb)
	clip_to(tb, ta)
	invert(tb)
	build(ta, all(tb))
	return all(ta)
end

function M.subtract(a: { Poly }, b: { Poly }): { Poly }
	if #a == 0 or #b == 0 then
		return a
	end
	if apart(M.bounds(a), M.bounds(b)) then
		return a
	end
	local ta, tb = tree(a), tree(b)
	invert(ta)
	clip_to(ta, tb)
	clip_to(tb, ta)
	invert(tb)
	clip_to(tb, ta)
	invert(tb)
	build(ta, all(tb))
	invert(ta)
	return all(ta)
end

function M.intersect(a: { Poly }, b: { Poly }): { Poly }
	if #a == 0 or #b == 0 then
		return {}
	end
	if apart(M.bounds(a), M.bounds(b)) then
		return {}
	end
	local ta, tb = tree(a), tree(b)
	invert(ta)
	clip_to(tb, ta)
	invert(tb)
	clip_to(ta, tb)
	clip_to(tb, ta)
	build(ta, all(tb))
	invert(ta)
	return all(ta)
end

-- A tree for drawing (a painter's BSP): walked from the camera's side of
-- each plane, it gives the polygons in exact back-to-front order from any
-- view, where sorting by depth fails on long faces. Each node's splitter is
-- the one of a few candidates that cuts the fewest of a sample of its
-- polygons, to keep the pieces few.
function M.view_tree(polys: { Poly }): Node
	local root = node()
	local cloned = table.create(#polys)
	for i, p in polys do
		cloned[i] = copy(p)
	end
	local stack: { any } = { root, cloned }
	local count = 0
	while #stack > 0 do
		local list = table.remove(stack) :: { Poly }
		local nd = table.remove(stack) :: Node
		local n = #list
		local best = list[1]
		if n > 4 then
			local cands = math.min(6, n)
			local samples = math.min(40, n)
			local best_score = math.huge
			for ci = 1, cands do
				local c = list[1 + (((ci - 1) * n) // cands)]
				local score = 0
				for si = 1, samples do
					local q = list[1 + (((si - 1) * n) // samples)]
					local front, back = false, false
					for _, v in q.v do
						local t = c.nx * v[1] + c.ny * v[2] + c.nz * v[3] - c.w
						if t > EPS then
							front = true
						elseif t < -EPS then
							back = true
						end
					end
					if front and back then
						score += 1
					end
				end
				if score < best_score then
					best, best_score = c, score
				end
			end
		end
		nd.plane = { best.nx, best.ny, best.nz, best.w }
		local pl = nd.plane :: { number }
		local f, b = {}, {}
		for _, p in list do
			split(pl[1], pl[2], pl[3], pl[4], p, nd.polys, nd.polys, f, b)
			count += 1
			if count % 64 == 0 then
				M.pause()
			end
		end
		if #f > 0 then
			nd.front = node()
			table.insert(stack, nd.front)
			table.insert(stack, f)
		end
		if #b > 0 then
			nd.back = node()
			table.insert(stack, nd.back)
			table.insert(stack, b)
		end
	end
	return root
end

-- A segment (an outline's) placed in a view tree: at the node whose plane
-- it lies on, split where it crosses others, so it's drawn just after its
-- face and under whatever is nearer.
function M.place_segment(root: Node, a: Vec, b: Vec)
	local E = 1e-4
	local stack: { any } = { root, a, b }
	while #stack > 0 do
		local q = table.remove(stack) :: Vec
		local p = table.remove(stack) :: Vec
		local nd = table.remove(stack) :: any
		local pl = nd.plane
		local function keep()
			nd.segs = nd.segs or {}
			table.insert(nd.segs, { p, q })
		end
		if not pl then
			keep()
		else
			local dp = pl[1] * p[1] + pl[2] * p[2] + pl[3] * p[3] - pl[4]
			local dq = pl[1] * q[1] + pl[2] * q[2] + pl[3] * q[3] - pl[4]
			if math.abs(dp) < E and math.abs(dq) < E then
				keep()
			elseif dp >= -E and dq >= -E then
				if nd.front then
					table.insert(stack, nd.front)
					table.insert(stack, p)
					table.insert(stack, q)
				else
					keep()
				end
			elseif dp <= E and dq <= E then
				if nd.back then
					table.insert(stack, nd.back)
					table.insert(stack, p)
					table.insert(stack, q)
				else
					keep()
				end
			else
				local t = dp / (dp - dq)
				local m = { p[1] + (q[1] - p[1]) * t, p[2] + (q[2] - p[2]) * t, p[3] + (q[3] - p[3]) * t }
				table.insert(stack, nd)
				table.insert(stack, p)
				table.insert(stack, m)
				table.insert(stack, nd)
				table.insert(stack, m)
				table.insert(stack, q)
			end
		end
	end
end

-- Many solids as one: pairs merged in a balanced tree, so disjoint ones
-- (a pattern's copies) are only concatenated.
function M.union_all(list: { { Poly } }): { Poly }
	local items = list
	if #items == 0 then
		return {}
	end
	while #items > 1 do
		local next_items = {}
		for i = 1, #items, 2 do
			if items[i + 1] then
				table.insert(next_items, M.union(items[i], items[i + 1]))
			else
				table.insert(next_items, items[i])
			end
		end
		items = next_items
	end
	return items[1]
end

return M
