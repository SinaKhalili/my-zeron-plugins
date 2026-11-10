-- The viewport: the mesh drawn on a canvas in software. Each frame projects
-- its corners through an orbiting camera, culls the faces turned away,
-- sorts the rest far to near (buckets by depth) and fills them flat-shaded
-- by a light that rides with the camera, runs of one shade as one path,
-- each run's creases stroked after it so nearer faces cover them. The last
-- frame's projection is kept for picking: what the pointer is over, and
-- where a ray from it meets the model or a plane.

local M = {}

export type Camera = { yaw: number, pitch: number, dist: number, tx: number, ty: number, tz: number, fov: number, ortho: boolean }

function M.camera(): Camera
	return { yaw = -55, pitch = 28, dist = 160, tx = 0, ty = 0, tz = 0, fov = 35, ortho = false }
end

local VIEWS = {
	iso = { yaw = -55, pitch = 28 },
	top = { yaw = -90, pitch = 89.9 },
	front = { yaw = -90, pitch = 0 },
	right = { yaw = 0, pitch = 0 },
}
M.VIEWS = VIEWS

-- The camera framing `b` (bounds) from where it looks now.
function M.fit(cam: Camera, b: { number }?): Camera
	local out = table.clone(cam)
	if not b then
		out.tx, out.ty, out.tz, out.dist = 0, 0, 0, 160
		return out
	end
	local cx, cy, cz = (b[1] + b[4]) / 2, (b[2] + b[5]) / 2, (b[3] + b[6]) / 2
	local dx, dy, dz = b[4] - b[1], b[5] - b[2], b[6] - b[3]
	local r = math.max(1, math.sqrt(dx * dx + dy * dy + dz * dz) / 2)
	out.tx, out.ty, out.tz = cx, cy, cz
	out.dist = r / math.sin(math.rad(cam.fov / 2)) * 1.15
	return out
end

type Basis = {
	ex: number, ey: number, ez: number,
	fx: number, fy: number, fz: number,
	rx: number, ry: number, rz: number,
	ux: number, uy: number, uz: number,
	s: number, k: number, cx: number, cy: number, ortho: boolean, near: number,
}

local function basis(cam: Camera, w: number, h: number): Basis
	local cp, sp = math.cos(math.rad(cam.pitch)), math.sin(math.rad(cam.pitch))
	local cy, sy = math.cos(math.rad(cam.yaw)), math.sin(math.rad(cam.yaw))
	local fx, fy, fz = -cp * cy, -cp * sy, -sp
	local rx, ry, rz = -sy, cy, 0
	-- u = r × f
	local ux = ry * fz - rz * fy
	local uy = rz * fx - rx * fz
	local uz = rx * fy - ry * fx
	local s = (h / 2) / math.tan(math.rad(cam.fov / 2))
	return {
		ex = cam.tx - fx * cam.dist, ey = cam.ty - fy * cam.dist, ez = cam.tz - fz * cam.dist,
		fx = fx, fy = fy, fz = fz, rx = rx, ry = ry, rz = rz, ux = ux, uy = uy, uz = uz,
		s = s, k = s / cam.dist, cx = w / 2, cy = h / 2, ortho = cam.ortho, near = cam.dist * 0.02,
	}
end
M.basis = basis

-- A point to the screen: x, y, depth (nil behind the camera).
local function project(B: Basis, x: number, y: number, z: number): (number?, number?, number?)
	local dx, dy, dz = x - B.ex, y - B.ey, z - B.ez
	local zc = dx * B.fx + dy * B.fy + dz * B.fz
	local xc = dx * B.rx + dy * B.ry + dz * B.rz
	local yc = dx * B.ux + dy * B.uy + dz * B.uz
	if B.ortho then
		return B.cx + xc * B.k, B.cy - yc * B.k, zc
	end
	if zc < B.near then
		return nil, nil, nil
	end
	return B.cx + xc * B.s / zc, B.cy - yc * B.s / zc, zc
end
M.project = project

-- The ray through a point of the view: origin and direction.
function M.ray(B: Basis, sx: number, sy: number): (number, number, number, number, number, number)
	if B.ortho then
		local a, b = (sx - B.cx) / B.k, -(sy - B.cy) / B.k
		return B.ex + B.rx * a + B.ux * b, B.ey + B.ry * a + B.uy * b, B.ez + B.rz * a + B.uz * b, B.fx, B.fy, B.fz
	end
	local a, b = (sx - B.cx) / B.s, -(sy - B.cy) / B.s
	local dx, dy, dz = B.fx + B.rx * a + B.ux * b, B.fy + B.ry * a + B.uy * b, B.fz + B.rz * a + B.uz * b
	local l = math.sqrt(dx * dx + dy * dy + dz * dz)
	return B.ex, B.ey, B.ez, dx / l, dy / l, dz / l
end

-- Where the ray through (sx, sy) meets the plane z = h, or nil.
function M.on_plane(B: Basis, sx: number, sy: number, h: number): (number?, number?)
	local ox, oy, oz, dx, dy, dz = M.ray(B, sx, sy)
	if math.abs(dz) < 1e-9 then
		return nil, nil
	end
	local t = (h - oz) / dz
	if t < 0 then
		return nil, nil
	end
	return ox + dx * t, oy + dy * t
end

local function clamp01(x: number): number
	return if x < 0 then 0 elseif x > 1 then 1 else x
end

local function hex2(x: number): string
	return string.format("%02x", math.floor(clamp01(x) * 255 + 0.5))
end

export type Look = {
	dark: boolean,
	base: { number },
	selected: { number },
	hover: { number },
	edge: string,
	grid: string,
	grid_major: string,
	axis_x: string,
	axis_y: string,
}

function M.look(dark: boolean): Look
	return {
		dark = dark,
		base = if dark then { 0.62, 0.67, 0.73 } else { 0.70, 0.75, 0.81 },
		selected = { 0.30, 0.56, 1.0 },
		hover = if dark then { 0.78, 0.83, 0.90 } else { 0.80, 0.86, 0.94 },
		edge = if dark then "#0b0e1299" else "#1d273566",
		grid = if dark then "#ffffff12" else "#00000010",
		grid_major = if dark then "#ffffff24" else "#00000022",
		axis_x = "#e5484dcc",
		axis_y = "#30a46ccc",
	}
end

-- Frame state kept for picking.
export type Frame = {
	B: Basis?,
	ray: boolean?,
	wire: boolean?,
	offx: { number }?,
	offy: { number }?,
	offz: { number }?,
	sx: { number },
	sy: { number },
	order: { number },
	count: number,
	mesh: any,
}

function M.frame(): Frame
	return { B = nil, sx = {}, sy = {}, order = {}, count = 0, mesh = nil }
end

local function nice_step(span: number): number
	local raw = span / 10
	local p = 10 ^ math.floor(math.log10(math.max(raw, 1e-6)))
	local m = raw / p
	return (if m < 1.5 then 1 elseif m < 3.5 then 2 elseif m < 7.5 then 5 else 10) * p
end

local function grid(c: any, B: Basis, look: Look, bounds: { number }?, cam: Camera)
	local ext
	if bounds then
		ext = math.max(math.abs(bounds[1]), math.abs(bounds[4]), math.abs(bounds[2]), math.abs(bounds[5]), 10) * 1.6
	else
		ext = cam.dist * 0.6
	end
	local step = nice_step(ext * 2)
	local n = math.ceil(ext / step)
	ext = n * step
	local function seg(x1: number, y1: number, x2: number, y2: number, paint: string, width: number)
		-- (Cut at the near plane: a grid runs behind the camera.)
		local steps = 1
		local ax, ay = project(B, x1, y1, 0)
		local bx, by = project(B, x2, y2, 0)
		if ax and bx then
			c:line(ax, ay, bx, by, paint, width)
			return
		end
		steps = 24
		local px, py = nil, nil
		for i = 0, steps do
			local t = i / steps
			local qx, qy = project(B, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, 0)
			if qx and px then
				c:line(px, py, qx, qy, paint, width)
			end
			px, py = qx, qy
		end
	end
	for i = -n, n do
		local v = i * step
		local paint = if i % 5 == 0 then look.grid_major else look.grid
		if i ~= 0 then
			seg(-ext, v, ext, v, paint, 1)
			seg(v, -ext, v, ext, paint, 1)
		end
	end
	seg(0, 0, ext, 0, look.axis_x, 1.5)
	seg(-ext, 0, 0, 0, look.grid_major, 1)
	seg(0, 0, 0, ext, look.axis_y, 1.5)
	seg(0, -ext, 0, 0, look.grid_major, 1)
	return step
end

-- (Top right, under the view buttons: the bottom is the tools' bars.)
local function triad(c: any, B: Basis, w: number)
	local ox, oy = w - 34, 64
	local L = 20
	local axes = {
		{ 1, 0, 0, "#e5484d", "X" },
		{ 0, 1, 0, "#30a46c", "Y" },
		{ 0, 0, 1, "#3e8ef7", "Z" },
	}
	-- Back to front, so the axis toward the viewer is on top.
	table.sort(axes, function(a, b)
		local da = a[1] * B.fx + a[2] * B.fy + a[3] * B.fz
		local db = b[1] * B.fx + b[2] * B.fy + b[3] * B.fz
		return da > db
	end)
	for _, a in axes do
		local x = a[1] * B.rx + a[2] * B.ry + a[3] * B.rz
		local y = a[1] * B.ux + a[2] * B.uy + a[3] * B.uz
		local tx, ty = ox + x * L, oy - y * L
		c:line(ox, oy, tx, ty, a[4], 2, { cap = "round" })
		c:text(a[5], ox + x * (L + 8), oy - y * (L + 8), { size = 10, color = a[4], align = "center", baseline = "middle", weight = 600 })
	end
end

export type Draw = {
	mesh: any?,
	cam: Camera,
	look: Look,
	bounds: { number }?,
	-- Part ids to light.
	selected: { [number]: boolean }?,
	hover: number?,
	wire: boolean?,
	frame: Frame,
	-- How far an exploded mesh's pieces have moved out, 0 to 1.
	explode: number?,
	-- Leave out the grid, the axes (a thumbnail's).
	grid: boolean?,
	triad: boolean?,
	-- Leave out the model: something else draws it (the GPU scene), and
	-- this keeps what picking needs (`pick` then casts a ray).
	model: boolean?,
}

-- The grid's step for these bounds and camera (what `draw` answers).
function M.step(bounds: { number }?, cam: Camera): number
	local ext
	if bounds then
		ext = math.max(math.abs(bounds[1]), math.abs(bounds[4]), math.abs(bounds[2]), math.abs(bounds[5]), 10) * 1.6
	else
		ext = cam.dist * 0.6
	end
	return nice_step(ext * 2)
end

-- Draws the scene; keeps the projection in `d.frame`.
function M.draw(c: any, w: number, h: number, d: Draw): number
	local B = basis(d.cam, w, h)
	local F = d.frame
	F.B = B
	F.mesh = d.mesh
	local step = 10
	if d.grid ~= false then
		step = grid(c, B, d.look, d.bounds, d.cam)
	end
	local mesh = d.mesh
	F.ray = d.model == false
	F.wire = d.wire == true
	if not mesh or mesh.triangles == 0 or d.model == false then
		F.count = 0
		-- (Where an exploded mesh's pieces are, for a ray to meet them.)
		local ox, oy, oz = {}, {}, {}
		if mesh and mesh.pieces then
			local a = math.clamp(d.explode or 0, 0, 1)
			local e = a * a * (3 - 2 * a)
			for i, pc in mesh.pieces do
				ox[i], oy[i], oz[i] = pc.dir[1] * e, pc.dir[2] * e, pc.dir[3] * e
			end
		end
		F.offx, F.offy, F.offz = ox, oy, oz
		if d.triad ~= false then
			triad(c, B, w)
		end
		return step
	end
	local vx, vy, vz = mesh.vx, mesh.vy, mesh.vz
	local nv = #vx
	-- An exploded mesh: each piece moved out along its way.
	local pieces = mesh.pieces
	local vp = mesh.vp
	local ex_ = math.clamp(d.explode or 0, 0, 1)
	local offx, offy, offz = {}, {}, {}
	if pieces then
		-- (Eased, so pieces leave and settle softly.)
		local e = ex_ * ex_ * (3 - 2 * ex_)
		for i, pc in pieces do
			offx[i], offy[i], offz[i] = pc.dir[1] * e, pc.dir[2] * e, pc.dir[3] * e
		end
	end
	F.offx, F.offy, F.offz = offx, offy, offz
	local sx, sy, sz = F.sx, F.sy, {}
	-- (Camera-space x and y too, to cut what crosses the near plane.)
	local xs, ys = {}, {}
	local ex, ey, ez = B.ex, B.ey, B.ez
	local fx, fy, fz, rx, ry, rz, ux, uy, uz = B.fx, B.fy, B.fz, B.rx, B.ry, B.rz, B.ux, B.uy, B.uz
	local s, k, cx, cy, near, ortho = B.s, B.k, B.cx, B.cy, B.near, B.ortho
	for i = 1, nv do
		local dx, dy, dz = vx[i] - ex, vy[i] - ey, vz[i] - ez
		if vp then
			local pi = vp[i]
			dx, dy, dz = dx + offx[pi], dy + offy[pi], dz + offz[pi]
		end
		local zc = dx * fx + dy * fy + dz * fz
		local xc = dx * rx + dy * ry + dz * rz
		local yc = dx * ux + dy * uy + dz * uz
		if ortho then
			sx[i], sy[i] = cx + xc * k, cy - yc * k
		elseif zc > near then
			sx[i], sy[i] = cx + xc * s / zc, cy - yc * s / zc
		else
			sx[i], sy[i] = math.huge, math.huge
		end
		sz[i] = zc
		xs[i], ys[i] = xc, yc
	end
	local tri, tn, tc, tp = mesh.tri, mesh.tn, mesh.tc, mesh.tp
	local np, nf, nb, nt0, nt1, ns0, ns1 = mesh.np, mesh.nf, mesh.nb, mesh.nt0, mesh.nt1, mesh.ns0, mesh.ns1
	-- Light: a key from over the viewer's left shoulder, a fill from the
	-- right, both riding with the camera.
	local lx, ly, lz = -fx * 0.75 - rx * 0.35 + ux * 0.55, -fy * 0.75 - ry * 0.35 + uy * 0.55, -fz * 0.75 - rz * 0.35 + uz * 0.55
	local ll = math.sqrt(lx * lx + ly * ly + lz * lz)
	lx, ly, lz = lx / ll, ly / ll, lz / ll
	local gx, gy, gz = -fx * 0.4 + rx * 0.8, -fy * 0.4 + ry * 0.8, -fz * 0.4 + rz * 0.8
	local gl = math.sqrt(gx * gx + gy * gy + gz * gz)
	gx, gy, gz = gx / gl, gy / gl, gz / gl
	-- Back to front, by the view tree: at each node, the side of its plane
	-- away from the camera first, then the node's own faces (and after them
	-- its outlines, as a negative entry), then the near side. A piece moved
	-- out sees the camera from where the camera is to it.
	local shade = {}
	local wire = d.wire == true
	local order = F.order
	local n = 0
	local function walk(root: number, cex: number, cey: number, cez: number)
		local stack = { root }
		while #stack > 0 do
			local x = table.remove(stack) :: number
			if x > 0 then
				local i4 = x * 4
				local side
				if ortho then
					side = -(np[i4 - 3] * fx + np[i4 - 2] * fy + np[i4 - 1] * fz)
				else
					side = np[i4 - 3] * cex + np[i4 - 2] * cey + np[i4 - 1] * cez - np[i4]
				end
				local fr, bk = nf[x], nb[x]
				-- (A stack: what's pushed last comes out first.)
				if side > 0 then
					if fr > 0 then table.insert(stack, fr) end
					table.insert(stack, -x)
					if bk > 0 then table.insert(stack, bk) end
				else
					if bk > 0 then table.insert(stack, bk) end
					table.insert(stack, -x)
					if fr > 0 then table.insert(stack, fr) end
				end
			else
				local nd = -x
				for t = nt0[nd], nt1[nd] do
					local i3 = t * 3
					local a, b, cc = tri[i3 - 2], tri[i3 - 1], tri[i3]
					-- (Wholly behind the camera: gone. Partly: cut at the near plane
					-- as it's painted.)
					if sx[a] ~= math.huge or sx[b] ~= math.huge or sx[cc] ~= math.huge then
						local nx, ny, nz = tn[i3 - 2], tn[i3 - 1], tn[i3]
						local facing
						if ortho then
							facing = -(nx * fx + ny * fy + nz * fz)
						else
							facing = nx * (cex - vx[a]) + ny * (cey - vy[a]) + nz * (cez - vz[a])
						end
						if facing > 0 or wire then
							n += 1
							order[n] = t
							local di = nx * lx + ny * ly + nz * lz
							local fi = nx * gx + ny * gy + nz * gz
							local li = 0.38 + 0.55 * (if di > 0 then di else 0) + 0.14 * (if fi > 0 then fi else 0)
							shade[t] = math.floor(math.min(li, 1.08) * 40 + 0.5)
						end
					end
				end
				if ns1[nd] >= ns0[nd] then
					n += 1
					order[n] = x
				end
			end
		end
	end
	if pieces then
		-- Pieces far to near (by their moved centres), each by its own tree.
		local ord = {}
		for i, pc in pieces do
			local c3 = pc.center
			local dz = (c3[1] + offx[i] - ex) * fx + (c3[2] + offy[i] - ey) * fy + (c3[3] + offz[i] - ez) * fz
			table.insert(ord, { i = i, z = dz })
		end
		table.sort(ord, function(a, b)
			return a.z > b.z
		end)
		for _, o in ord do
			local i = o.i
			walk(pieces[i].root, ex - offx[i], ey - offy[i], ez - offz[i])
		end
	else
		walk(1, ex, ey, ez)
	end
	F.count = n
	-- Paint: runs of one colour and shade as one path, filled when the run
	-- ends or a node's outlines come (drawn over what's before them, under
	-- what's after).
	local colors = mesh.colors
	local look = d.look
	local selected = d.selected or {}
	local hover = d.hover
	local cache: { [number]: string } = {}
	local function paint_of(ci: number, part: number, level: number): string
		local mode = if selected[part] then 1 elseif hover == part then 2 else 0
		local key = (ci * 4 + mode) * 64 + level
		local p = cache[key]
		if p then
			return p
		end
		local base = if mode == 1 then look.selected elseif mode == 2 then look.hover else (colors[ci] or look.base)
		local li = level / 40
		p = "#" .. hex2(base[1] * li) .. hex2(base[2] * li) .. hex2(base[3] * li) .. (if wire then "40" else "")
		cache[key] = p
		return p
	end
	local edge = look.edge
	-- A point between two corners where it meets the near plane, on screen.
	local function cut(i: number, j: number): (number, number)
		local t = (near - sz[i]) / (sz[j] - sz[i])
		local x = xs[i] + (xs[j] - xs[i]) * t
		local y = ys[i] + (ys[j] - ys[i]) * t
		return cx + x * s / near, cy - y * s / near
	end
	-- A triangle crossing the near plane: the part in front of it.
	local function clipped(p: any, a: number, b: number, c3: number): any
		local ids = { a, b, c3 }
		local first = true
		for k = 1, 3 do
			local i, j = ids[k], ids[(k % 3) + 1]
			local inside, next_inside = sx[i] ~= math.huge, sx[j] ~= math.huge
			if inside then
				p = if first then p:move(sx[i], sy[i]) else p:line(sx[i], sy[i])
				first = false
			end
			if inside ~= next_inside then
				local qx, qy = cut(i, j)
				p = if first then p:move(qx, qy) else p:line(qx, qy)
				first = false
			end
		end
		return if first then p else p:close()
	end
	local sa, sb = mesh.sa, mesh.sb
	local run_key, run_paint = -1, ""
	local path = nil :: any
	local segs = 0
	local function fill()
		if path then
			c:fill(path, run_paint)
			-- (A hairline of the same paint closes the antialiased seams
			-- between neighbouring triangles.)
			if not wire then
				c:stroke(path, run_paint, 0.75, { join = "round" })
			end
			path = nil
		end
		segs = 0
	end
	for i = 1, n do
		local t = order[i]
		if t > 0 then
			local i3 = t * 3
			local a, b, cc = tri[i3 - 2], tri[i3 - 1], tri[i3]
			local part = tp[t]
			local ci = tc[t]
			local level = shade[t]
			local mode = if selected[part] then 1 elseif hover == part then 2 else 0
			local key = ((ci * 4 + mode) * 64 + level)
			if key ~= run_key or segs > 6000 then
				fill()
				run_key = key
				run_paint = paint_of(ci, part, level)
			end
			if not path then
				path = ui.path()
			end
			if sx[a] ~= math.huge and sx[b] ~= math.huge and sx[cc] ~= math.huge then
				path = path:move(sx[a], sy[a]):line(sx[b], sy[b]):line(sx[cc], sy[cc]):close()
			else
				path = clipped(path, a, b, cc)
			end
			segs += 4
		else
			local nd = -t
			fill()
			run_key = -1
			local edges = nil :: any
			for si = ns0[nd], ns1[nd] do
				local a, b = sa[si], sb[si]
				local ax, bx = sx[a], sx[b]
				if ax ~= math.huge and bx ~= math.huge then
					edges = (edges or ui.path()):move(ax, sy[a]):line(bx, sy[b])
				elseif ax ~= math.huge or bx ~= math.huge then
					-- (Crossing the near plane: up to where it meets it.)
					local inside = if ax ~= math.huge then a else b
					local qx, qy = cut(a, b)
					edges = (edges or ui.path()):move(sx[inside], sy[inside]):line(qx, qy)
				end
			end
			if edges then
				c:stroke(edges, edge, 1, { cap = "round" })
			end
		end
	end
	fill()
	if d.triad ~= false then
		triad(c, B, w)
	end
	return step
end

-- The part under (px, py) in the last frame, nearest first: its id, the
-- triangle and where on it (in the model).
-- The same by a ray through the point, against every triangle (the
-- nearest it meets from its front): for a frame whose model something
-- else drew.
local function raycast(F: Frame, px: number, py: number): (number?, number?, { number }?)
	local mesh, B = F.mesh, F.B
	if not mesh or not B then
		return nil, nil, nil
	end
	local ox, oy, oz, dx, dy, dz = M.ray(B, px, py)
	local vx, vy, vz, tri, tn = mesh.vx, mesh.vy, mesh.vz, mesh.tri, mesh.tn
	local vp, offx, offy, offz = mesh.vp, F.offx or {}, F.offy or {}, F.offz or {}
	local both = F.wire == true
	local best, best_t = nil, math.huge
	local bmx, bmy, bmz = 0, 0, 0
	for t = 1, mesh.triangles do
		local i3 = t * 3
		local nx, ny, nz = tn[i3 - 2], tn[i3 - 1], tn[i3]
		local den = nx * dx + ny * dy + nz * dz
		-- (Faces turned away aren't seen, so aren't pointed at.)
		if den < -1e-9 or (both and den > 1e-9) then
			local a = tri[i3 - 2]
			local mx, my, mz = 0, 0, 0
			if vp then
				local pi = vp[a]
				mx, my, mz = offx[pi] or 0, offy[pi] or 0, offz[pi] or 0
			end
			local ax, ay, az = vx[a] + mx, vy[a] + my, vz[a] + mz
			local dist = (nx * (ax - ox) + ny * (ay - oy) + nz * (az - oz)) / den
			if dist > 0 and dist < best_t then
				-- Where it meets the face's plane: inside the triangle?
				local hx, hy, hz = ox + dx * dist, oy + dy * dist, oz + dz * dist
				local b, c3 = tri[i3 - 1], tri[i3]
				local bx, by, bz = vx[b] + mx, vy[b] + my, vz[b] + mz
				local cx, cy, cz = vx[c3] + mx, vy[c3] + my, vz[c3] + mz
				local function side(px1: number, py1: number, pz1: number, qx: number, qy: number, qz: number): number
					local ex, ey, ez = qx - px1, qy - py1, qz - pz1
					local wx, wy, wz = hx - px1, hy - py1, hz - pz1
					return nx * (ey * wz - ez * wy) + ny * (ez * wx - ex * wz) + nz * (ex * wy - ey * wx)
				end
				local e = -1e-7
				if side(ax, ay, az, bx, by, bz) >= e and side(bx, by, bz, cx, cy, cz) >= e and side(cx, cy, cz, ax, ay, az) >= e then
					best, best_t = t, dist
					bmx, bmy, bmz = mx, my, mz
				end
			end
		end
	end
	if not best then
		return nil, nil, nil
	end
	local i3 = best * 3
	return mesh.tp[best], best, { ox + dx * best_t - bmx, oy + dy * best_t - bmy, oz + dz * best_t - bmz, tn[i3 - 2], tn[i3 - 1], tn[i3] }
end

function M.pick(F: Frame, px: number, py: number): (number?, number?, { number }?)
	if F.ray then
		return raycast(F, px, py)
	end
	local mesh = F.mesh
	local B = F.B
	if not mesh or not B or F.count == 0 then
		return nil, nil, nil
	end
	local sx, sy, tri = F.sx, F.sy, mesh.tri
	for i = F.count, 1, -1 do
		local t = F.order[i]
		if t <= 0 then
			-- (A node's outlines, not a face.)
			continue
		end
		local i3 = t * 3
		local a, b, c = tri[i3 - 2], tri[i3 - 1], tri[i3]
		if sx[a] == math.huge or sx[b] == math.huge or sx[c] == math.huge then
			-- (Crossing the near plane: too close to point at.)
			continue
		end
		local ax, ay, bx, by, cx, cy = sx[a], sy[a], sx[b], sy[b], sx[c], sy[c]
		local d1 = (bx - ax) * (py - ay) - (by - ay) * (px - ax)
		local d2 = (cx - bx) * (py - by) - (cy - by) * (px - bx)
		local d3 = (ax - cx) * (py - cy) - (ay - cy) * (px - cx)
		local neg = d1 < 0 or d2 < 0 or d3 < 0
		local pos = d1 > 0 or d2 > 0 or d3 > 0
		if not (neg and pos) then
			-- Where on its plane.
			local nx, ny, nz = mesh.tn[i3 - 2], mesh.tn[i3 - 1], mesh.tn[i3]
			-- (On an exploded mesh, its piece is moved out: meet the face
			-- where it shows, and say where that is on the design itself.)
			local mx, my, mz = 0, 0, 0
			if mesh.vp and F.offx then
				local pi = mesh.vp[a]
				mx, my, mz = F.offx[pi] or 0, F.offy[pi] or 0, F.offz[pi] or 0
			end
			local w = nx * (mesh.vx[a] + mx) + ny * (mesh.vy[a] + my) + nz * (mesh.vz[a] + mz)
			local ox, oy, oz, dx, dy, dz = M.ray(B, px, py)
			local den = nx * dx + ny * dy + nz * dz
			local hit = nil
			if math.abs(den) > 1e-12 then
				local tt = (w - (nx * ox + ny * oy + nz * oz)) / den
				hit = { ox + dx * tt - mx, oy + dy * tt - my, oz + dz * tt - mz, nx, ny, nz }
			end
			return mesh.tp[t], t, hit
		end
	end
	return nil, nil, nil
end

-- Turning, panning and zooming the camera.
function M.orbit(cam: Camera, dx: number, dy: number): Camera
	local out = table.clone(cam)
	out.yaw = cam.yaw - dx * 0.4
	out.pitch = math.clamp(cam.pitch + dy * 0.4, -89.9, 89.9)
	return out
end

function M.pan(cam: Camera, B: Basis, dx: number, dy: number): Camera
	local out = table.clone(cam)
	local per = if B.ortho then 1 / B.k else cam.dist / B.s
	local mx, my = -dx * per, dy * per
	out.tx = cam.tx + B.rx * mx + B.ux * my
	out.ty = cam.ty + B.ry * mx + B.uy * my
	out.tz = cam.tz + B.rz * mx + B.uz * my
	return out
end

function M.zoom(cam: Camera, factor: number): Camera
	local out = table.clone(cam)
	out.dist = math.clamp(cam.dist * factor, 1, 20000)
	return out
end

function M.view(cam: Camera, name: string): Camera
	local v = VIEWS[name]
	local out = table.clone(cam)
	if v then
		out.yaw, out.pitch = v.yaw, v.pitch
	end
	return out
end

return M
