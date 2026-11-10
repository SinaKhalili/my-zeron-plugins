-- The viewport on the GPU, where this Zeron has it (zgx's `ui.scene3d`
-- with a mesh of its own triangles): the same mesh the canvas paints, as
-- flat-shaded meshes with depth, multisampling, a sun that casts shadows
-- and outlines along the creases. Without it (an older Zeron, or the
-- orthographic view, which the scene has no camera for) the canvas draws.
--
-- The design's frame is Z up, in millimetres; the scene's is Y up, and its
-- camera sees from 0.05 to 200 units. So everything sits in one group
-- turned -90° about X and scaled to a couple of units across, and the
-- camera is placed the same way: what it shows lines up with what the
-- canvas's own projection says, point for point.

local M = {}

-- Whether this Zeron draws scenes of a plugin's own triangles.
M.available = (function(): boolean
	local ok, made = pcall(function()
		if type(ui.scene3d) ~= "function" or type(ui.mesh) ~= "function" then
			return false
		end
		ui.mesh { geometry = { positions = { 0, 0, 0, 1, 0, 0, 0, 1, 0 } } }
		return true
	end)
	return ok and made == true
end)()

local function hex(rgb: { number }): string
	local function ch(x: number): string
		return string.format("%02x", math.floor(math.clamp(x, 0, 1) * 255 + 0.5))
	end
	return "#" .. ch(rgb[1]) .. ch(rgb[2]) .. ch(rgb[3])
end

-- The scale that brings these bounds to about two units across.
function M.scale(bounds: { number }?): number
	if not bounds then
		return 1 / 60
	end
	local dx, dy, dz = bounds[4] - bounds[1], bounds[5] - bounds[2], bounds[6] - bounds[3]
	local diag = math.sqrt(dx * dx + dy * dy + dz * dz)
	return 2 / math.max(diag, 1e-3)
end

export type Scene = {
	mesh: any,
	bounds: { number }?,
	-- The camera (a state of render's Camera), followed.
	cam: any,
	dark: () -> boolean,
	-- How a part shows now: "selected", "hover" or nil. Followed.
	state: ((part: number) -> string?)?,
	-- See-through.
	wire: () -> boolean,
	-- How far an exploded mesh's pieces are out, 0 to 1. Followed.
	explode: (() -> number)?,
}

-- A tube of three sides along each crease, so outlines are hidden where
-- the model hides them.
local function outlines(mesh: any, piece: number?, r: number): any?
	local sa, sb, vx, vy, vz, vp = mesh.sa, mesh.sb, mesh.vx, mesh.vy, mesh.vz, mesh.vp
	local pos, idx = {}, {}
	local n = 0
	for i = 1, #sa do
		local a, b = sa[i], sb[i]
		if piece == nil or vp[a] == piece then
			local ax, ay, az, bx, by, bz = vx[a], vy[a], vz[a], vx[b], vy[b], vz[b]
			local dx, dy, dz = bx - ax, by - ay, bz - az
			local l = math.sqrt(dx * dx + dy * dy + dz * dz)
			if l > 1e-9 then
				dx, dy, dz = dx / l, dy / l, dz / l
				-- Two directions across it.
				local ux, uy, uz
				if math.abs(dz) < 0.9 then
					ux, uy, uz = dy, -dx, 0
				else
					ux, uy, uz = 0, dz, -dy
				end
				local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
				ux, uy, uz = ux / ul, uy / ul, uz / ul
				local wx, wy, wz = dy * uz - dz * uy, dz * ux - dx * uz, dx * uy - dy * ux
				local base = n
				for k = 0, 2 do
					local ang = k * 2.0943951
					local c, s = math.cos(ang) * r, math.sin(ang) * r
					local ox, oy, oz = ux * c + wx * s, uy * c + wy * s, uz * c + wz * s
					table.insert(pos, ax + ox)
					table.insert(pos, ay + oy)
					table.insert(pos, az + oz)
					table.insert(pos, bx + ox)
					table.insert(pos, by + oy)
					table.insert(pos, bz + oz)
				end
				n += 6
				for k = 0, 2 do
					local a0, b0 = base + k * 2 + 1, base + k * 2 + 2
					local a1, b1 = base + ((k + 1) % 3) * 2 + 1, base + ((k + 1) % 3) * 2 + 2
					table.insert(idx, a0)
					table.insert(idx, a1)
					table.insert(idx, b1)
					table.insert(idx, a0)
					table.insert(idx, b1)
					table.insert(idx, b0)
				end
			end
		end
	end
	if n == 0 then
		return nil
	end
	return { positions = pos, indices = idx }
end

-- The scene for a mesh. (Its geometry is made once: a new mesh is a new
-- scene; the camera, the colours and the pieces' places follow state.)
function M.scene(o: Scene): Node
	local mesh = o.mesh
	local k = M.scale(o.bounds)
	local vx, vy, vz, tri, tn, tc, tp, vp = mesh.vx, mesh.vy, mesh.vz, mesh.tri, mesh.tn, mesh.tc, mesh.tp, mesh.vp
	-- Triangles by piece (of an exploded mesh), part and colour: one mesh
	-- each, so a part lights by its material alone.
	local groups: { [string]: any } = {}
	local order: { any } = {}
	for t = 1, mesh.triangles do
		local i3 = t * 3
		local a, b, c = tri[i3 - 2], tri[i3 - 1], tri[i3]
		local piece = if vp then vp[a] else 0
		local part, ci = tp[t], tc[t]
		local key = `{piece}:{part}:{ci}`
		local g = groups[key]
		if not g then
			g = { piece = piece, part = part, ci = ci, pos = {}, normals = {} }
			groups[key] = g
			table.insert(order, g)
		end
		local pos, nn = g.pos, g.normals
		local n = #pos
		pos[n + 1], pos[n + 2], pos[n + 3] = vx[a], vy[a], vz[a]
		pos[n + 4], pos[n + 5], pos[n + 6] = vx[b], vy[b], vz[b]
		pos[n + 7], pos[n + 8], pos[n + 9] = vx[c], vy[c], vz[c]
		local m = #nn
		nn[m + 1], nn[m + 2], nn[m + 3] = tn[i3 - 2], tn[i3 - 1], tn[i3]
	end
	local state = o.state
	local b = o.bounds
	local diag = if b then math.sqrt((b[4] - b[1]) ^ 2 + (b[5] - b[2]) ^ 2 + (b[6] - b[3]) ^ 2) else 100
	-- Each piece's objects (piece 0: a mesh that isn't exploded).
	local by_piece: { [number]: { any } } = {}
	for _, g in order do
		local base = mesh.colors[g.ci]
		local list = by_piece[g.piece]
		if not list then
			list = {}
			by_piece[g.piece] = list
		end
		local part = g.part
		table.insert(list, ui.mesh {
			geometry = { positions = g.pos, face_normals = g.normals },
			material = {
				color = function(): string
					local s = if state then state(part) else nil
					if s == "selected" then
						return "#4d8dff"
					end
					local rgb = base or (if o.dark() then { 0.72, 0.76, 0.81 } else { 0.78, 0.82, 0.87 })
					if s == "hover" then
						return hex({ rgb[1] * 0.75 + 0.25, rgb[2] * 0.75 + 0.25, rgb[3] * 0.75 + 0.25 })
					end
					return hex(rgb)
				end,
				roughness = 0.62,
				metallic = 0,
				opacity = function(): number
					return if o.wire() then 0.28 else 1
				end,
			},
		})
	end
	local objects: { any } = {}
	local r = diag * 0.0011
	local function edge_mesh(piece: number?): any?
		local g = outlines(mesh, piece, r)
		if not g then
			return nil
		end
		return ui.mesh {
			geometry = g,
			material = {
				color = function(): string
					return if o.dark() then "#0c0f14" else "#27303d"
				end,
				unlit = true,
			},
		}
	end
	if mesh.pieces then
		for i, pc in mesh.pieces do
			local list = by_piece[i] or {}
			local e = edge_mesh(i)
			if e then
				table.insert(list, e)
			end
			local dir = pc.dir
			local explode = o.explode
			local group: { [any]: any } = {
				position = function(): { number }
					local a = math.clamp(if explode then explode() else 0, 0, 1)
					local f = a * a * (3 - 2 * a)
					return { dir[1] * f, dir[2] * f, dir[3] * f }
				end,
			}
			for _, obj in list do
				table.insert(group, obj)
			end
			table.insert(objects, ui.group(group))
		end
	else
		for _, obj in by_piece[0] or {} do
			table.insert(objects, obj)
		end
		local e = edge_mesh(nil)
		if e then
			table.insert(objects, e)
		end
	end
	-- Everything in the design's frame, turned and scaled into the scene's.
	local root: { [any]: any } = { rotation = { -90, 0, 0 }, scale = k }
	for _, obj in objects do
		table.insert(root, obj)
	end
	local cam = o.cam
	-- (A design's x, y, z is the scene's x, z, -y.)
	local function eye(): (number, number, number, number, number, number)
		local c = cam:get()
		local cp, sp = math.cos(math.rad(c.pitch)), math.sin(math.rad(c.pitch))
		local cy, sy = math.cos(math.rad(c.yaw)), math.sin(math.rad(c.yaw))
		local fx, fy, fz = -cp * cy, -cp * sy, -sp
		return c.tx - fx * c.dist, c.ty - fy * c.dist, c.tz - fz * c.dist, fx, fy, fz
	end
	return ui.scene3d {
		absolute = true,
		left = 0,
		top = 0,
		right = 0,
		bottom = 0,
		pointer_events = "none",
		label = "3D view",
		shadows = true,
		environment = "none",
		camera = {
			fov = function(): number
				return cam:get().fov
			end,
			position = function(): { number }
				local x, y, z = eye()
				return { x * k, z * k, -y * k }
			end,
			target = function(): { number }
				local c = cam:get()
				return { c.tx * k, c.tz * k, -c.ty * k }
			end,
		},
		-- The sun, fixed over the design's front left (it casts the
		-- shadows); a softer light from the viewer, so no face seen is
		-- black; and the sky and floor's.
		ui.light { kind = "directional", direction = { 0.42, -0.78, -0.5 }, intensity = 1.35 },
		ui.light {
			kind = "directional",
			direction = function(): { number }
				local _, _, _, fx, fy, fz = eye()
				return { fx, fz, -fy }
			end,
			intensity = 0.4,
		},
		ui.light { kind = "hemisphere", color = "#dfe7f2", ground = "#5d6470", intensity = 0.5 },
		ui.group(root),
	}
end

return M
