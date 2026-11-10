-- The CAD tab, beside the chat: a toolbar, the viewport (orbit, pan,
-- zoom, pick, sketch, measure), and under it the design's parameters as
-- sliders, its parts, the selected part's numbers, and a line to ask the
-- agent for a change.

local render = require("./render")
local gpu = require("./gpu")
local geom = require("./geom")
local expr = require("./expr")
local examples = require("./examples")

local Button = require("@ds/button")
local IconButton = require("@ds/icon_button").IconButton
local Segmented = require("@ds/segmented")
local Slider = require("@ds/slider")
local Switch = require("@ds/switch")
local TextField = require("@ds/text_field")
local Text = require("@ds/text")
local EmptyState = require("@ds/empty_state")
local ListRow = require("@ds/list_row").ListRow

return function(zeron: any, docs: any)
	-- Each chat's camera, kept while the window is open.
	local cameras: { [string]: any } = {}

	local function round(v: number): number
		return math.floor(v * 100 + 0.5) / 100
	end

	local function fmt(v: number): string
		local r = round(v)
		if r == math.floor(r) then
			return tostring(math.floor(r))
		end
		return tostring(r)
	end

	-- What a field's text means: a number, an expression, or nil (and why).
	local function parse(text: string): (any, string?)
		local t = string.gsub(text, "^%s*(.-)%s*$", "%1")
		if t == "" then
			return nil, "Empty"
		end
		local n = tonumber(t)
		if n then
			return n, nil
		end
		local why = expr.check(t)
		if why then
			return nil, why
		end
		return t, nil
	end

	local function shown(v: any): string
		if type(v) == "number" then
			return fmt(v)
		elseif v == nil then
			return ""
		end
		return tostring(v)
	end

	-- A number field on the inspector: commits on Enter or leaving it.
	local NumField = ui.component(function(props: { label: string, value: any, on_commit: (any) -> (), w: number? })
		local text = ui.use_state(shown(props.value))
		local wrong = ui.use_state("")
		return TextField {
			value = text,
			label = props.label,
			size = "sm",
			w = props.w,
			grow = if props.w then nil else 1,
			error = function(): string?
				local e = wrong:get()
				return if e == "" then nil else e
			end,
			select_on_focus = true,
			on_commit = function(t: string)
				local v, why = parse(t)
				if v == nil then
					wrong:set(why or "Not a number")
					return
				end
				wrong:set("")
				props.on_commit(v)
			end,
		}
	end)

	local function next_name(d: any, base: string): string
		local n = 1
		for _, p in d.parts do
			if p.type == string.lower(base) or (p.name and string.find(p.name, "^" .. base)) then
				n += 1
			end
		end
		return `{base} {n}`
	end

	local TOOLS = {
		{ value = "select", label = "Select" },
		{ value = "box", label = "Box" },
		{ value = "cylinder", label = "Cylinder" },
		{ value = "sketch", label = "Sketch" },
		{ value = "measure", label = "Measure" },
	}

	local Tab = ui.component(function(props: { tab: any })
		local data = props.tab.data or {}
		local sid: string = data.session
		local appearance = zeron.live("appearance")
		local function doc(): any
			docs.tick:get()
			return docs.get(sid)
		end
		local function dark(): boolean
			local a = appearance and appearance()
			return a == "dark"
		end

		local cam = ui.use_state(cameras[sid] or render.camera())
		ui.effect(function()
			cameras[sid] = cam:get()
		end)
		local hover = ui.use_state(nil :: number?)
		local wire = ui.use_state(false)
		local tool = ui.use_state("select")
		local mode = ui.use_state("add")
		local height = ui.use_state("10")
		local sheet = ui.use_state("params")
		local pts = ui.use_state({} :: { { number } })
		local plane = ui.use_state(0)
		local cursor_pt = ui.use_state(nil :: { number }?)
		local measure = ui.use_state({} :: { { number } })
		local ask = ui.use_state("")
		-- A section across the design, the exploded view, and what's shown in
		-- the design's place while the pointer is over it (a variant, a past
		-- version): { kind = "variant", i } or { kind = "history", snap, label }.
		local section_on = ui.use_state(false)
		local sec_axis = ui.use_state("x")
		local sec_at = ui.use_state(0.5)
		local sec_flip = ui.use_state(false)
		local explode_on = ui.use_state(false)
		local explode_amt = ui.use_state(0)
		local preview = ui.use_state(nil :: any)
		-- Whether the exploded pieces are out at all (which mesh shows).
		local moved = ui.computed(function(): boolean
			return explode_amt:get() > 0.02
		end)

		local frame = render.frame()
		local size = { w = 600, h = 400 }
		local snap_step = 1

		-- Framing: a design seen for the first time, or a new one.
		ui.effect(function()
			local d = doc()
			if d.want_fit and d.status == "ready" and d.bounds then
				d.want_fit = false
				cam:set(render.fit(cam:peek(), d.bounds))
			end
		end)

		-- The section follows its controls and each build; the exploded pieces
		-- each build, while they're on.
		ui.effect(function()
			local d = doc()
			if section_on:get() and d.bounds then
				docs.section(sid, { axis = sec_axis:get(), at = sec_at:get(), flip = sec_flip:get() })
			elseif not section_on:get() then
				docs.section(sid, nil)
			end
		end)
		ui.effect(function()
			local d = doc()
			if explode_on:get() then
				if d.bounds then
					docs.explode(sid)
				end
			else
				docs.unexplode(sid)
			end
		end)
		-- Pieces fly out (or back) over 0.6 s, eased in render.
		local anim: any = nil
		local function animate_explode(to: number, done: (() -> ())?)
			if anim then
				pcall(function()
					anim:cancel()
				end)
			end
			anim = ui.task(function()
				local from = explode_amt:peek()
				local t0 = os.clock()
				while true do
					local k = math.min(1, (os.clock() - t0) / 0.6)
					explode_amt:set(from + (to - from) * k)
					if k >= 1 then
						break
					end
					ui.sleep(16):await()
				end
				if done then
					done()
				end
			end)
		end
		-- The camera pulls back to hold the pieces as they go out, and comes
		-- back where it was as they return.
		local cam_before: any = nil
		local framed: any = nil
		ui.effect(function()
			local d = doc()
			local ex = d.exploded
			if explode_on:get() and ex and ex.mesh and framed ~= ex.mesh and d.bounds then
				framed = ex.mesh
				local b = table.clone(d.bounds)
				for _, pc in ex.mesh.pieces do
					for a = 1, 3 do
						local v = pc.dir[a]
						if v < 0 then
							b[a] = math.min(b[a], d.bounds[a] + v)
						else
							b[a + 3] = math.max(b[a + 3], d.bounds[a + 3] + v)
						end
					end
				end
				local now = cam:peek()
				cam_before = cam_before or now
				cam:set(render.fit(now, b))
			end
		end)
		local function set_explode(on: boolean)
			if on then
				section_on:set(false)
				explode_on:set(true)
				animate_explode(1)
			else
				animate_explode(0, function()
					explode_on:set(false)
					framed = nil
					if cam_before then
						cam:set(cam_before)
						cam_before = nil
					end
				end)
			end
		end
		local function set_section(on: boolean)
			if on then
				explode_on:set(false)
				explode_amt:set(0)
			end
			section_on:set(on)
		end

		-- What a preview shows: its mesh and bounds, once built.
		local function preview_entry(pv: any): any
			if not pv then
				return nil
			end
			local d = docs.get(sid)
			if pv.kind == "variant" then
				return d.variants[pv.i]
			elseif pv.kind == "history" then
				return docs.preview(pv.snap)
			end
			return nil
		end

		-- Back to a clean slate when the tool changes.
		ui.effect(function()
			local _ = tool:get()
			pts:set({})
			cursor_pt:set(nil)
			measure:set({})
		end)

		local function snap(v: number): number
			return math.floor(v / snap_step + 0.5) * snap_step
		end

		-- The plane a sketch starts on: the flat face clicked, else the grid.
		local function plane_at(x: number, y: number): number
			local _, _, hit = render.pick(frame, x, y)
			if hit and math.abs(hit[6]) > 0.95 then
				return round(hit[3])
			end
			return 0
		end

		local function on_plane(x: number, y: number, z: number): { number }?
			if not frame.B then
				return nil
			end
			local px, py = render.on_plane(frame.B, x, y, z)
			if not px then
				return nil
			end
			return { snap(px :: number), snap(py :: number), z }
		end

		local function add_feature(node: any)
			local d = docs.get(sid)
			local m = mode:peek()
			if m ~= "add" then
				node.mode = m
			end
			local index = 0
			docs.edit(sid, function(design: any)
				design.body = design.body or {}
				table.insert(design.body, node)
				index = #design.body
			end, `Added {node.name or node.type}`)
			docs.select(sid, `body.{index}`)
			sheet:set("part")
			tool:set("select")
			local _ = d
		end

		local function feature_height(z0: number): (number, number)
			local h = tonumber(height:peek()) or 10
			h = math.max(0.01, math.abs(h))
			if mode:peek() == "cut" then
				-- (From the face down, and a hair above it, so the cut opens.)
				return round(z0 - h), h + 0.02
			end
			return z0, h
		end

		local function finish_sketch()
			local p = pts:peek()
			if #p < 3 then
				pts:set({})
				return
			end
			local z0 = plane:peek()
			local z, h = feature_height(z0)
			local points = {}
			for _, q in p do
				table.insert(points, { round(q[1]), round(q[2]) })
			end
			add_feature({ type = "extrude", name = next_name(docs.get(sid), "Sketch"), points = points, h = round(h), translate = { 0, 0, z } })
		end

		local function click(x: number, y: number)
			local d = docs.get(sid)
			local t = tool:peek()
			if t == "select" then
				if preview:peek() then
					return
				end
				local part, _, hit = render.pick(frame, x, y)
				local p = part and d.parts[part]
				docs.select(sid, if p then p.path else nil)
				-- (Where on the face, for point-and-ask.)
				if p and hit then
					docs.pick(sid, { point = { hit[1], hit[2], hit[3] }, normal = { hit[4], hit[5], hit[6] }, path = p.path })
				end
				if p then
					sheet:set("part")
				end
				return
			end
			if t == "measure" then
				local _, _, hit = render.pick(frame, x, y)
				local q = if hit then { hit[1], hit[2], hit[3] } else on_plane(x, y, 0)
				if not q then
					return
				end
				local m = measure:peek()
				if #m >= 2 then
					m = {}
				end
				local nm = table.clone(m)
				table.insert(nm, q)
				measure:set(nm)
				return
			end
			local p = pts:peek()
			if #p == 0 then
				plane:set(plane_at(x, y))
			end
			local q = on_plane(x, y, plane:peek())
			if not q then
				return
			end
			if t == "box" then
				if #p == 0 then
					pts:set({ q })
				else
					local a = p[1]
					local w, dd = math.abs(q[1] - a[1]), math.abs(q[2] - a[2])
					if w < 1e-6 or dd < 1e-6 then
						return
					end
					local z, h = feature_height(plane:peek())
					add_feature({
						type = "box",
						name = next_name(d, "Box"),
						size = { round(w), round(dd), round(h) },
						translate = { round(math.min(a[1], q[1])), round(math.min(a[2], q[2])), z },
					})
				end
			elseif t == "cylinder" then
				if #p == 0 then
					pts:set({ q })
				else
					local a = p[1]
					local r = math.sqrt((q[1] - a[1]) ^ 2 + (q[2] - a[2]) ^ 2)
					if r < 1e-6 then
						return
					end
					local z, h = feature_height(plane:peek())
					add_feature({
						type = "cylinder",
						name = next_name(d, "Cylinder"),
						r = round(r),
						h = round(h),
						translate = { round(a[1]), round(a[2]), z },
					})
				end
			elseif t == "sketch" then
				-- Back on the first point: closed.
				if #p >= 3 and frame.B then
					local fx, fy = render.project(frame.B, p[1][1], p[1][2], p[1][3])
					if fx and math.abs(fx - x) < 10 and math.abs((fy :: number) - y) < 10 then
						finish_sketch()
						return
					end
				end
				local np = table.clone(p)
				table.insert(np, q)
				pts:set(np)
			end
		end

		-- Pointer: a drag turns the camera (pans with Shift or Option); a
		-- press let go where it began is a click.
		local press: any = nil
		local function on_press(e: any)
			press = { x = e.local_x, y = e.local_y, cam = cam:peek(), moved = false, pan = e.shift or e.alt }
		end
		local function on_move(e: any)
			local x, y = e.local_x, e.local_y
			if press then
				local dx, dy = x - press.x, y - press.y
				if not press.moved and dx * dx + dy * dy > 16 then
					press.moved = true
					hover:set(nil)
				end
				if press.moved then
					if press.pan then
						cam:set(render.pan(press.cam, render.basis(press.cam, size.w, size.h), dx, dy))
					else
						cam:set(render.orbit(press.cam, dx, dy))
					end
				end
				return
			end
			local t = tool:peek()
			if t == "select" then
				local d = docs.get(sid)
				if d.mesh and d.mesh.triangles < 30000 then
					local part = render.pick(frame, x, y)
					if part ~= hover:peek() then
						hover:set(part)
					end
				end
			elseif t ~= "measure" then
				local z = if #pts:peek() > 0 then plane:peek() else 0
				cursor_pt:set(on_plane(x, y, z))
			end
		end
		local function on_release(e: any)
			local p = press
			press = nil
			if p and not p.moved then
				click(e.local_x, e.local_y)
			end
		end
		local function on_wheel(e: any): boolean
			local c = cam:peek()
			if e.shift then
				cam:set(render.pan(c, render.basis(c, size.w, size.h), -(e.dx or 0), -(e.dy or 0)))
			else
				local k = if e.ctrl or e.cmd then 0.012 else 0.004
				cam:set(render.zoom(c, math.exp((e.dy or 0) * k)))
			end
			return true
		end

		-- What's drawn over the model: a sketch in progress, a measurement.
		local function overlay(c: any, own: boolean)
			local B = frame.B
			if not B then
				return
			end
			local accent = "#3e8ef7"
			local d = doc()
			-- The section's plane: a frame across the design where it cuts.
			if section_on:get() and d.section and d.section.pos and d.bounds then
				local b = d.bounds
				local m = math.max(b[4] - b[1], b[5] - b[2], b[6] - b[3]) * 0.08
				local pos = d.section.pos
				local ax = sec_axis:get()
				local corners
				if ax == "x" then
					corners = { { pos, b[2] - m, b[3] - m }, { pos, b[5] + m, b[3] - m }, { pos, b[5] + m, b[6] + m }, { pos, b[2] - m, b[6] + m } }
				elseif ax == "y" then
					corners = { { b[1] - m, pos, b[3] - m }, { b[4] + m, pos, b[3] - m }, { b[4] + m, pos, b[6] + m }, { b[1] - m, pos, b[6] + m } }
				else
					corners = { { b[1] - m, b[2] - m, pos }, { b[4] + m, b[2] - m, pos }, { b[4] + m, b[5] + m, pos }, { b[1] - m, b[5] + m, pos } }
				end
				local path = ui.path()
				local ok = true
				for i, q in corners do
					local x, y = render.project(B, q[1], q[2], q[3])
					if not x then
						ok = false
						break
					end
					path = if i == 1 then path:move(x, y) else path:line(x, y)
				end
				if ok then
					path = path:close()
					c:fill(path, "#ff6a3d12")
					c:stroke(path, "#ff6a3daa", 1.25, { dash = { 6, 4 } })
				end
			end
			-- The face pointed at: a pin on it, standing out along its normal.
			if own and d.pick and tool:get() == "select" and d.bounds then
				local pk = d.pick
				local b = d.bounds
				local len = math.max(b[4] - b[1], b[5] - b[2], b[6] - b[3]) * 0.12
				local x, y = render.project(B, pk.point[1], pk.point[2], pk.point[3])
				local x2, y2 = render.project(B, pk.point[1] + pk.normal[1] * len, pk.point[2] + pk.normal[2] * len, pk.point[3] + pk.normal[3] * len)
				if x and x2 then
					c:line(x, y, x2, y2, "#ff4fa3", 2, { cap = "round" })
					c:circle(x2 :: number, y2 :: number, 3, "#ff4fa3")
					c:circle(x, y, 5.5, "#ffffff")
					c:circle(x, y, 3.5, "#ff4fa3")
				end
			end
			local t = tool:get()
			local p = pts:get()
			local cur = cursor_pt:get()
			local function at(q: { number }): (number?, number?)
				local x, y = render.project(B, q[1], q[2], q[3])
				return x, y
			end
			if t == "box" and #p == 1 and cur then
				local a = p[1]
				local corners = { { a[1], a[2], a[3] }, { cur[1], a[2], a[3] }, { cur[1], cur[2], a[3] }, { a[1], cur[2], a[3] } }
				local path = ui.path()
				for i, q in corners do
					local x, y = at(q)
					if not x then
						return
					end
					path = if i == 1 then path:move(x, y) else path:line(x, y)
				end
				path = path:close()
				c:fill(path, "#3e8ef733")
				c:stroke(path, accent, 1.5)
				local x, y = at({ (a[1] + cur[1]) / 2, (a[2] + cur[2]) / 2, a[3] })
				if x then
					c:text(`{fmt(math.abs(cur[1] - a[1]))} × {fmt(math.abs(cur[2] - a[2]))}`, x, y, { size = 11, color = accent, align = "center", baseline = "middle", weight = 600 })
				end
			elseif t == "cylinder" and #p == 1 and cur then
				local a = p[1]
				local r = math.sqrt((cur[1] - a[1]) ^ 2 + (cur[2] - a[2]) ^ 2)
				local path = ui.path()
				for i = 0, 48 do
					local ang = i / 48 * 2 * math.pi
					local x, y = at({ a[1] + r * math.cos(ang), a[2] + r * math.sin(ang), a[3] })
					if not x then
						return
					end
					path = if i == 0 then path:move(x, y) else path:line(x, y)
				end
				path = path:close()
				c:fill(path, "#3e8ef733")
				c:stroke(path, accent, 1.5)
				local x, y = at(a)
				if x then
					c:circle(x, y, 2.5, accent)
					c:text(`⌀ {fmt(r * 2)}`, x, (y :: number) - 12, { size = 11, color = accent, align = "center", weight = 600 })
				end
			elseif t == "sketch" and #p > 0 then
				local path = ui.path()
				for i, q in p do
					local x, y = at(q)
					if x then
						path = if i == 1 then path:move(x, y) else path:line(x, y)
					end
				end
				if cur then
					local x, y = at(cur)
					if x then
						path = path:line(x, y)
					end
				end
				c:stroke(path, accent, 1.5, { join = "round" })
				for i, q in p do
					local x, y = at(q)
					if x then
						c:circle(x, y, if i == 1 then 4 else 2.5, accent)
					end
				end
			end
			if (t == "box" or t == "cylinder" or t == "sketch") and cur then
				local x, y = at(cur)
				if x then
					c:circle(x, y, 3, accent)
				end
			end
			if t == "measure" then
				local m = measure:get()
				for _, q in m do
					local x, y = at(q)
					if x then
						c:circle(x, y, 3.5, "#e8893a")
					end
				end
				if #m == 2 then
					local x1, y1 = at(m[1])
					local x2, y2 = at(m[2])
					if x1 and x2 then
						c:line(x1, y1, x2, y2, "#e8893a", 1.5, { dash = { 5, 4 } })
						local dx, dy, dz = m[2][1] - m[1][1], m[2][2] - m[1][2], m[2][3] - m[1][3]
						local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
						c:text(`{fmt(dist)} mm`, (x1 + x2) / 2, (y1 + y2) / 2 - 12, { size = 12, color = "#e8893a", align = "center", weight = 700 })
					end
				end
			end
		end

		-- What's shown: a preview while one is pointed at, else the section,
		-- else the exploded pieces (once they've moved), else the design.
		local function shown(): (any, { number }?, boolean, number?)
			local d = doc()
			local mesh, bounds, own = d.mesh, d.bounds, true
			local explode = nil
			local pv = preview_entry(preview:get())
			if pv and pv.mesh then
				mesh, bounds, own = pv.mesh, pv.bounds or bounds, false
			elseif section_on:get() and d.section and d.section.mesh then
				mesh = d.section.mesh
			elseif explode_on:get() and explode_amt:get() > 0.02 and d.exploded and d.exploded.mesh then
				mesh, explode = d.exploded.mesh, explode_amt:get()
			end
			return mesh, bounds, own, explode
		end

		-- The GPU draws the model where this Zeron can (gpu.luau); the
		-- canvas does otherwise, and for the orthographic view.
		local gpu_failed = ui.use_state(false)
		local function on_gpu(): boolean
			return gpu.available and not gpu_failed:get() and not cam:get().ortho
		end
		-- (Read apart from the camera's turning: only its kind.)
		local ortho = ui.computed(function(): boolean
			return cam:get().ortho == true
		end)
		local scene_ids = 0
		local scene_now: any = nil
		local scene = ui.presence(function(): string?
			if not (gpu.available and not gpu_failed:get()) then
				return nil
			end
			if ortho:get() then
				return nil
			end
			local d = doc()
			local mesh, bounds, own = d.mesh, d.bounds, true
			local pv = preview_entry(preview:get())
			if pv and pv.mesh then
				mesh, bounds, own = pv.mesh, pv.bounds or bounds, false
			elseif section_on:get() and d.section and d.section.mesh then
				mesh = d.section.mesh
			elseif explode_on:get() and d.exploded and d.exploded.mesh and moved:get() then
				mesh = d.exploded.mesh
			end
			if not mesh or mesh.triangles == 0 then
				return nil
			end
			if not mesh.gid then
				scene_ids += 1
				mesh.gid = scene_ids
			end
			scene_now = { mesh = mesh, bounds = bounds, own = own }
			return tostring(mesh.gid)
		end, function(): Node
			local now = scene_now
			local ok, made = pcall(gpu.scene, {
				mesh = now.mesh,
				bounds = now.bounds,
				cam = cam,
				dark = dark,
				wire = function(): boolean
					return wire:get()
				end,
				explode = function(): number
					return explode_amt:get()
				end,
				state = if now.own
					then function(part: number): string?
						local d = doc()
						local p = d.parts[part]
						if p and d.selected and p.path == d.selected then
							return "selected"
						end
						if tool:get() == "select" and hover:get() == part then
							return "hover"
						end
						return nil
					end
					else nil,
			})
			if ok then
				return made
			end
			print(`cad: the GPU view failed, drawing on the canvas instead: {made}`)
			ui.task(function()
				gpu_failed:set(true)
			end)
			return ui.column {}
		end, { absolute = true, left = 0, top = 0, right = 0, bottom = 0, pointer_events = "none" })

		-- Under the scene: the grid.
		local grid_frame = render.frame()
		local grid_canvas = ui.canvas {
			absolute = true,
			left = 0,
			top = 0,
			right = 0,
			bottom = 0,
			pointer_events = "none",
			draw = function(c: any, w: number, h: number)
				if not on_gpu() then
					return
				end
				local _, bounds = shown()
				render.draw(c, w, h, { mesh = nil, cam = cam:get(), look = render.look(dark()), bounds = bounds, frame = grid_frame, triad = false })
			end,
		}

		local canvas = ui.canvas {
			absolute = true,
			left = 0,
			top = 0,
			right = 0,
			bottom = 0,
			label = function(): string
				local d = doc()
				return if d.design then `3D view of {d.design.name or "the design"}` else "Empty 3D view"
			end,
			cursor = function(): string
				local t = tool:get()
				if t == "select" then
					return if hover:get() then "pointer" else "grab"
				end
				return "crosshair"
			end,
			draw = function(c: any, w: number, h: number)
				local d = doc()
				size.w, size.h = w, h
				local sel = {}
				if d.selected then
					for _, p in d.parts do
						if p.path == d.selected then
							sel[p.id] = true
						end
					end
				end
				local mesh, bounds, own, explode = shown()
				if on_gpu() then
					-- The scene under this canvas draws the model: here, only
					-- what picking needs and what's drawn over it.
					render.draw(c, w, h, {
						mesh = mesh,
						cam = cam:get(),
						look = render.look(dark()),
						bounds = bounds,
						wire = wire:get(),
						frame = frame,
						explode = explode,
						grid = false,
						model = false,
					})
					snap_step = math.max(0.5, render.step(bounds, cam:peek()) / 10)
					overlay(c, own and explode == nil)
					return
				end
				local step = render.draw(c, w, h, {
					mesh = mesh,
					cam = cam:get(),
					look = render.look(dark()),
					bounds = bounds,
					selected = if own then sel else {},
					hover = if own and tool:get() == "select" then hover:get() else nil,
					wire = wire:get(),
					frame = frame,
					explode = explode,
				})
				snap_step = math.max(0.5, step / 10)
				overlay(c, own and explode == nil)
			end,
			on_press = on_press,
			on_pointer_move = on_move,
			on_release = on_release,
			on_wheel = on_wheel,
		}

		-- Words over the viewport -------------------------------------------

		local function status(): string
			local d = doc()
			if not d.loaded then
				return "Loading…"
			elseif d.status == "building" then
				return "Building…"
			elseif d.status == "error" then
				return "Error"
			elseif d.status == "ready" and d.bounds then
				local b = d.bounds
				return `{fmt(b[4] - b[1])} × {fmt(b[5] - b[2])} × {fmt(b[6] - b[3])} {d.design and d.design.units or "mm"} · {#d.parts} parts`
			end
			return ""
		end

		local function hint(): string
			local t = tool:get()
			local n = #pts:get()
			if t == "select" then
				return "Drag to orbit · Shift-drag to pan · scroll to zoom · click a part"
			elseif t == "box" then
				return if n == 0 then "Click a corner, on the grid or on a flat face" else "Click the opposite corner"
			elseif t == "cylinder" then
				return if n == 0 then "Click the centre, on the grid or on a flat face" else "Click to set the radius"
			elseif t == "sketch" then
				return if n == 0 then "Click to place points, on the grid or a flat face" elseif n < 3 then "Keep clicking to add points" else "Click the first point, or Close, to finish"
			elseif t == "measure" then
				return "Click two points on the model or the grid"
			end
			return ""
		end

		local function view_button(name: string, label: string): Node
			return Button {
				label,
				tone = "ghost",
				size = "xs",
				on_click = function()
					cam:set(render.view(cam:peek(), name))
				end,
			}
		end

		local function selected_part(): any
			local d = doc()
			return docs.part(d, d.selected)
		end

		-- What the agent is told along with the person's words: the face they
		-- pointed at (where, which way it faces, whose it is), else the part.
		local function ask_text(words: string): string
			local d = docs.get(sid)
			local p = docs.part(d, d.selected)
			local pk = d.pick
			if p and pk and pk.path == p.path then
				local q, n = pk.point, pk.normal
				return `In the CAD design, at the point ({fmt(q[1])}, {fmt(q[2])}, {fmt(q[3])}) mm on the {docs.facing(n)} face of the part "{p.name or p.type}" ({p.type} at {p.path}; the face's normal is ({fmt(n[1])}, {fmt(n[2])}, {fmt(n[3])})): {words}`
			end
			if p then
				return `In the CAD design, for the part "{p.name or p.type}" ({p.type} at {p.path}): {words}`
			end
			return `In the CAD design: {words}`
		end
		local function ask_now(words: string)
			zeron.compose(ask_text(words))
			zeron.toast("In the message box: press Return to send it")
		end

		local function send_ask()
			local words = ask:peek()
			if string.find(words, "%S") == nil then
				local p = docs.part(docs.get(sid), docs.get(sid).selected)
				zeron.compose(if p then ask_text("") else "In the CAD design: ")
				return
			end
			zeron.compose(ask_text(words))
			ask:set("")
			zeron.toast("In the message box: press Return to send it")
		end

		local viewport = ui.column {
			grow = 1,
			w_full = true,
			relative = true,
			overflow = "hidden",
			min_h = 160,
			grid_canvas,
			scene,
			canvas,
			-- Top: what it is, and the views.
			ui.row {
				absolute = true,
				left = 10,
				right = 8,
				top = 6,
				items = "center",
				gap = "$space.1",
				pointer_events = "none",
				ui.text {
					status,
					text_size = "$font.size.xs",
					color = function(): string
						return if doc().status == "error" then "$danger" else "$text.tertiary"
					end,
					tabular = true,
					grow = 1,
					truncate = true,
					pointer_events = "none",
				},
				view_button("iso", "Iso"),
				view_button("top", "Top"),
				view_button("front", "Front"),
				view_button("right", "Right"),
			},
			-- A preview in the design's place: what it is.
			ui.show(function(): boolean
				return preview:get() ~= nil
			end, ui.row {
				absolute = true,
				left = 0,
				right = 0,
				top = 34,
				justify = "center",
				pointer_events = "none",
				ui.row {
					bg = "$accent",
					rounded = 12,
					px = 10,
					py = 3,
					gap = "$space.2",
					items = "center",
					ui.text {
						function(): string
							local pv = preview:get()
							if not pv then
								return ""
							end
							local e = preview_entry(pv)
							local busy = e and e.status == "building"
							local what = if pv.kind == "variant" then ((e and e.label) or "a variant") else (pv.label or "a past version")
							return `{if busy then "Building" else "Previewing"} {what}`
						end,
						text_size = "$font.size.xs",
						color = "#ffffff",
						weight = 600,
					},
					ui.show(function(): boolean
						local pv = preview:get()
						return pv ~= nil and pv.pinned == true
					end, ui.button {
						on_click = function()
							preview:set(nil)
						end,
						label = "Back to current",
						px = 6,
						rounded = 8,
						bg = "#ffffff33",
						hover = { bg = "#ffffff55" },
						ui.text { "Back to current", text_size = "$font.size.xs", color = "#ffffff", weight = 600 },
					}),
				},
			}),
			-- Bottom: what the tool does, or the build's error.
			ui.column {
				absolute = true,
				left = 10,
				right = 10,
				bottom = 8,
				gap = "$space.1",
				pointer_events = "none",
				ui.show(function(): boolean
					return doc().status == "error"
				end, ui.text {
					function(): string
						return doc().error or ""
					end,
					text_size = "$font.size.xs",
					color = "$danger",
					wrap = true,
					pointer_events = "none",
				}),
				-- Section: which axis, which side, where along it.
				ui.show(section_on, ui.row {
					w_full = true,
					items = "center",
					gap = "$space.2",
					ui.text { "Section", text_size = "$font.size.xs", color = "#ff6a3d", weight = 600 },
					Segmented {
						value = sec_axis,
						label = "Section across",
						options = { { value = "x", label = "X" }, { value = "y", label = "Y" }, { value = "z", label = "Z" } },
					},
					IconButton {
						icon = "restart",
						label = "Keep the other side",
						size = "sm",
						lit = sec_flip,
						on_click = function()
							sec_flip:set(not sec_flip:peek())
						end,
					},
					Slider { value = sec_at, min = 0, max = 1, step = 0.005, label = "Where it cuts", grow = 1 },
					ui.text {
						function(): string
							local d = doc()
							if not d.bounds then
								return ""
							end
							return `{sec_axis:get()} = {fmt(docs.section_plane(d.bounds, sec_axis:get(), sec_at:get()))}`
						end,
						text_size = "$font.size.xs",
						color = "$text.secondary",
						tabular = true,
						w = 64,
					},
				}),
				-- Exploded: how far out, and back.
				ui.show(explode_on, ui.row {
					w_full = true,
					items = "center",
					gap = "$space.2",
					ui.text { "Explode", text_size = "$font.size.xs", color = "$accent", weight = 600 },
					Slider { value = explode_amt, min = 0, max = 1, step = 0.01, label = "How far apart", grow = 1 },
					ui.text {
						function(): string
							local d = doc()
							local ex = d.exploded
							if ex and ex.mesh then
								return `{#ex.mesh.pieces} pieces`
							end
							return "Splitting…"
						end,
						text_size = "$font.size.xs",
						color = "$text.secondary",
					},
					Button {
						ui.text {
							function(): string
								return if explode_amt:get() > 0.5 then "Collapse" else "Explode"
							end,
						},
						size = "xs",
						tone = "secondary",
						on_click = function()
							animate_explode(if explode_amt:peek() > 0.5 then 0 else 1)
						end,
					},
				}),
				-- Point-and-ask: the face just clicked, and what to ask of it.
				ui.show(function(): boolean
					local d = doc()
					return d.pick ~= nil and tool:get() == "select" and preview:get() == nil and docs.part(d, d.selected) ~= nil
				end, ui.row {
					w_full = true,
					items = "center",
					gap = "$space.1",
					flex_wrap = true,
					ui.text {
						function(): string
							local d = doc()
							local p = docs.part(d, d.selected)
							if not d.pick or not p then
								return ""
							end
							return `{docs.facing(d.pick.normal)} face of {p.name or p.type}:`
						end,
						text_size = "$font.size.xs",
						color = "#ff4fa3",
						weight = 600,
						pr = "$space.1",
					},
					Button { "Hole here", size = "xs", tone = "secondary", on_click = function() ask_now("add a 5 mm hole through the part here, square to this face.") end },
					Button { "Round its edges", size = "xs", tone = "secondary", on_click = function() ask_now("round (fillet) the edges around this face.") end },
					Button { "Thicker here", size = "xs", tone = "secondary", on_click = function() ask_now("make the part 2 mm thicker at this face.") end },
					Button { "Boss here", size = "xs", tone = "secondary", on_click = function() ask_now("add a cylindrical boss standing out of this face here.") end },
					Button { "Ask…", size = "xs", tone = "ghost", on_click = function() ask_now("") end },
				}),
				ui.row {
					items = "center",
					gap = "$space.2",
					pointer_events = "none",
					ui.text { hint, text_size = "$font.size.xs", color = "$text.tertiary", grow = 1, truncate = true, pointer_events = "none" },
					ui.show(function(): boolean
						return tool:get() == "sketch" and #pts:get() > 0
					end, ui.row {
						gap = "$space.1",
						Button { "Close", size = "xs", on_click = finish_sketch },
						Button { "Cancel", size = "xs", tone = "ghost", on_click = function() pts:set({}) end },
					}),
				},
			},
			-- Empty: how to begin.
			ui.show(function(): boolean
				local d = doc()
				return d.loaded and d.design == nil
			end, ui.column {
				absolute = true,
				left = 0,
				right = 0,
				top = 0,
				bottom = 0,
				items = "center",
				justify = "center",
				gap = "$space.3",
				p = "$space.5",
				EmptyState {
					icon = "widget",
					size = "sm",
					title = "Nothing modelled yet",
					body = "Describe a part in the chat and the agent models it here. Or draw one: pick Box, Cylinder or Sketch and click on the grid.",
					action = {
						label = "Start with a box",
						on_click = function()
							local d = docs.get(sid)
							d.want_fit = true
							docs.set(sid, {
								name = "Untitled",
								units = "mm",
								params = {},
								body = { { type = "box", name = "Box 1", size = { 40, 30, 20 }, translate = { -20, -15, 0 } } },
							}, nil, nil, "Started with a box")
						end,
					},
				},
				ui.row {
					gap = "$space.1",
					flex_wrap = true,
					justify = "center",
					ui.text { "Examples:", text_size = "$font.size.xs", color = "$text.tertiary" },
					ui.each(examples.list, function(e: any): Node
						return Button {
							e.label,
							size = "xs",
							tone = "secondary",
							on_click = function()
								docs.get(sid).want_fit = true
								docs.set(sid, docs.clone(e.design), {}, nil, `Example: {e.label}`)
							end,
						}
					end, { direction = "row", gap = "$space.1" }),
				},
			}),
		}

		-- Toolbar -------------------------------------------------------------

		local function export_stl()
			local d = docs.get(sid)
			local name = (d.design and d.design.name) or "design"
			local text = docs.stl(d, name)
			if not text then
				zeron.toast("Nothing to export yet")
				return
			end
			ui.task(function()
				local file = ui.save_file({ name = `{name}.stl` }):await()
				if file then
					ui.write_file(file, text):await()
					zeron.toast(`Saved {file.name}`)
				end
			end)
		end

		local function save_json()
			local d = docs.get(sid)
			if not d.design then
				zeron.toast("Nothing to save yet")
				return
			end
			local name = d.design.name or "design"
			ui.task(function()
				local file = ui.save_file({ name = `{name}.cad.json` }):await()
				if file then
					ui.write_file(file, ui.json.encode({ design = d.design, values = d.values }, { pretty = true })):await()
					zeron.toast(`Saved {file.name}`)
				end
			end)
		end

		local function open_json()
			ui.task(function()
				local files = ui.open_files({ title = "Open a design", filters = { { "Designs", { "json" } } } }):await()
				local file = files and files[1]
				if not file then
					return
				end
				local text = ui.read_file(file):await()
				local ok, v = pcall(ui.json.decode, text)
				if not ok or type(v) ~= "table" then
					zeron.toast("That file isn't a design")
					return
				end
				local design = if v.design then v.design else v
				docs.get(sid).want_fit = true
				docs.set(sid, design, v.values or {}, nil, `Opened {file.name}`)
			end)
		end

		local header = ui.row {
			w_full = true,
			items = "center",
			gap = "$space.1",
			px = "$space.3",
			pt = "$space.2",
			pb = "$space.1",
			ui.text {
				function(): string
					local d = doc()
					return if d.design then (d.design.name or "Untitled") else "CAD"
				end,
				text_size = "$font.size.md",
				weight = 600,
				color = "$text.primary",
				truncate = true,
				grow = 1,
			},
			IconButton {
				icon = "arrow-left",
				label = "Undo",
				size = "sm",
				disabled = function(): boolean
					return #doc().undo == 0
				end,
				on_click = function()
					docs.undo(sid)
				end,
			},
			IconButton {
				icon = "arrow-right",
				label = "Redo",
				size = "sm",
				disabled = function(): boolean
					return #doc().redo == 0
				end,
				on_click = function()
					docs.redo(sid)
				end,
			},
			IconButton {
				icon = "expand-arrows",
				label = "Fit to view",
				size = "sm",
				on_click = function()
					cam:set(render.fit(cam:peek(), docs.get(sid).bounds))
				end,
			},
			IconButton {
				icon = function(): string
					return if wire:get() then "eye-closed" else "eye"
				end,
				label = "See through",
				size = "sm",
				lit = wire,
				on_click = function()
					wire:set(not wire:peek())
				end,
			},
			IconButton {
				icon = "tuning",
				label = function(): string
					return if cam:get().ortho then "Orthographic: switch to perspective" else "Perspective: switch to orthographic"
				end,
				size = "sm",
				lit = function(): boolean
					return cam:get().ortho
				end,
				on_click = function()
					local c = table.clone(cam:peek())
					c.ortho = not c.ortho
					cam:set(c)
				end,
			},
			IconButton {
				icon = "scissors",
				label = "Section view",
				size = "sm",
				lit = section_on,
				on_click = function()
					set_section(not section_on:peek())
				end,
			},
			IconButton {
				icon = "split-columns",
				label = "Exploded view",
				size = "sm",
				lit = explode_on,
				on_click = function()
					set_explode(not explode_on:peek())
				end,
			},
			IconButton {
				icon = "palette",
				label = "Ask for variations",
				size = "sm",
				on_click = function()
					sheet:set("variants")
					zeron.compose("In the CAD design: propose 4 distinct variations of this design with propose_variants (different styles, proportions or features), each with a short label.")
					zeron.toast("In the message box: press Return to send it")
				end,
			},
			IconButton { icon = "folder", label = "Open a design (.json)", size = "sm", on_click = open_json },
			IconButton { icon = "document", label = "Save the design (.json)", size = "sm", on_click = save_json },
			IconButton { icon = "upload-minimalistic", label = "Export STL", size = "sm", on_click = export_stl },
		}

		local tools = ui.row {
			w_full = true,
			items = "center",
			gap = "$space.2",
			px = "$space.3",
			pb = "$space.2",
			flex_wrap = true,
			Segmented { value = tool, options = TOOLS, label = "Tool" },
			ui.show(function(): boolean
				local t = tool:get()
				return t == "box" or t == "cylinder" or t == "sketch"
			end, ui.row {
				items = "center",
				gap = "$space.2",
				Segmented {
					value = mode,
					label = "Add or cut",
					options = { { value = "add", label = "Add" }, { value = "cut", label = "Cut" } },
				},
				TextField {
					value = height,
					name = "Height or depth",
					size = "sm",
					w = 84,
					inputmode = "decimal",
					trailing = ui.text { "mm", text_size = "$font.size.xs", color = "$text.tertiary" },
				},
			}),
		}

		-- Parameters ------------------------------------------------------------

		local drag_end: any = nil
		local function param_row(p: any): Node?
			local d = docs.get(sid)
			local now = d.values[p.id]
			if now == nil then
				now = p.value
			end
			local label = p.label or p.id
			if type(p.value) == "boolean" or p.type == "bool" or p.type == "boolean" then
				local on = ui.use_state(now == true or now == 1)
				return ui.row {
					w_full = true,
					items = "center",
					gap = "$space.2",
					ui.text { label, text_size = "$font.size.sm", color = "$text.primary", grow = 1 },
					Switch {
						value = on,
						label = label,
						on_change = function(v: boolean)
							docs.set_value(sid, p.id, v, true)
						end,
					},
				}
			end
			if type(now) ~= "number" then
				-- (A derived value: shown, not set.)
				local env = geom.environment(d.design, d.values)
				local v = env[p.id]
				return ui.row {
					w_full = true,
					gap = "$space.2",
					ui.text { label, text_size = "$font.size.sm", color = "$text.secondary", grow = 1 },
					ui.text { if v then fmt(v) else tostring(now), text_size = "$font.size.sm", color = "$text.tertiary", tabular = true },
				}
			end
			local min = tonumber(p.min) or math.min(0, now)
			local max = tonumber(p.max) or math.max(now * 2, min + 10)
			local step = tonumber(p.step) or (if max - min > 20 then 1 else 0.1)
			local value = ui.use_state(now)
			local unit = if p.unit then " " .. p.unit else ""
			return ui.column {
				w_full = true,
				gap = "$space.1",
				ui.row {
					w_full = true,
					items = "center",
					ui.text { label, text_size = "$font.size.sm", color = "$text.primary", grow = 1 },
					ui.text {
						function(): string
							return fmt(value:get()) .. unit
						end,
						text_size = "$font.size.sm",
						color = "$text.secondary",
						tabular = true,
					},
				},
				Slider {
					value = value,
					min = min,
					max = max,
					step = step,
					label = label,
					w_full = true,
					on_change = function(v: number)
						docs.set_value(sid, p.id, v, false)
						if drag_end then
							pcall(function()
								drag_end:cancel()
							end)
						end
						drag_end = ui.task(function()
							ui.sleep(700):await()
							docs.end_drag(sid)
						end)
					end,
				},
			}
		end

		local params = ui.presence(function(): string
			local d = doc()
			return `{d.drev}`
		end, function(): Node
			local d = docs.get(sid)
			local list = if d.design and type(d.design.params) == "table" then d.design.params else {}
			if #list == 0 then
				return ui.column {
					w_full = true,
					p = "$space.3",
					ui.text {
						if d.design then "No parameters. Ask the agent to make this design parametric (\"make the width and hole size adjustable\")." else "A design's parameters show here as sliders.",
						text_size = "$font.size.sm",
						color = "$text.tertiary",
						wrap = true,
					},
				}
			end
			local rows = {}
			for _, p in list do
				if type(p) == "table" and type(p.id) == "string" then
					local row = param_row(p)
					if row then
						table.insert(rows, row)
					end
				end
			end
			return ui.column { w_full = true, gap = "$space.3", px = "$space.3", py = "$space.2", table.unpack(rows) }
		end, { w_full = true })

		-- Parts -----------------------------------------------------------------

		local MODE_WORD = { cut = "Cut", intersect = "Intersect" }
		local parts = ui.presence(function(): string
			local d = doc()
			return `{d.built}:{#d.parts}`
		end, function(): Node
			local d = docs.get(sid)
			if #d.parts == 0 then
				return ui.column {
					w_full = true,
					p = "$space.3",
					ui.text { "Parts show here once there's a design.", text_size = "$font.size.sm", color = "$text.tertiary" },
				}
			end
			local rows = {}
			for _, p in d.parts do
				local depth = select(2, string.gsub(p.path, "children", ""))
				table.insert(rows, ListRow {
					label = p.name or p.type,
					selected = function(): boolean
						return doc().selected == p.path
					end,
					on_click = function()
						docs.select(sid, p.path)
					end,
					on_hover = function(inside: boolean)
						hover:set(if inside then p.id else nil)
					end,
					ui.row {
						w_full = true,
						items = "center",
						gap = "$space.2",
						px = "$space.3",
						py = "$space.1",
						pl = 12 + depth * 14,
						ui.text { p.name or p.type, text_size = "$font.size.sm", color = "$text.primary", truncate = true, grow = 1 },
						ui.text { p.type, text_size = "$font.size.xs", color = "$text.tertiary" },
						ui.show(MODE_WORD[p.mode or ""] ~= nil, ui.text {
							MODE_WORD[p.mode or ""] or "",
							text_size = "$font.size.xs",
							color = if p.mode == "cut" then "$danger" else "$accent",
						}),
					},
				})
			end
			return ui.column { w_full = true, py = "$space.1", table.unpack(rows) }
		end, { w_full = true })

		-- The selected part ------------------------------------------------------

		local FIELDS: { [string]: { { string } } } = {
			box = { { "size", "1", "Width" }, { "size", "2", "Depth" }, { "size", "3", "Height" }, { "radius", "", "Corner radius" } },
			cylinder = { { "d", "", "Diameter" }, { "r", "", "Radius" }, { "r1", "", "Bottom radius" }, { "r2", "", "Top radius" }, { "d1", "", "Bottom ⌀" }, { "d2", "", "Top ⌀" }, { "h", "", "Height" } },
			sphere = { { "d", "", "Diameter" }, { "r", "", "Radius" } },
			torus = { { "R", "", "Ring radius" }, { "r", "", "Tube radius" } },
			extrude = { { "h", "", "Height" }, { "circle", "", "Radius" } },
			revolve = { { "angle", "", "Angle" } },
		}
		-- Fields a type always shows, set or not.
		local ALWAYS: { [string]: { [string]: boolean } } = {
			box = { size = true },
			cylinder = { h = true },
			extrude = { h = true },
		}

		local FIELD_WORD = { size = { "width", "depth", "height" }, translate = { "X", "Y", "Z" }, rotate = { "turn X", "turn Y", "turn Z" } }
		local function set_field(path: string, key: string, index: string, v: any)
			local was = geom.at(docs.get(sid).design, path)
			local word = if index ~= "" and FIELD_WORD[key] then FIELD_WORD[key][tonumber(index) :: number] else key
			local label = `{(was and (was.name or was.type)) or path}: {word} → {shown(v)}`
			docs.edit(sid, function(design: any)
				local node = geom.at(design, path)
				if not node then
					return
				end
				if index ~= "" then
					local i = tonumber(index) :: number
					local cur = node[key]
					if type(cur) ~= "table" then
						cur = if cur == nil then { 0, 0, 0 } else { cur, cur, cur }
						if key == "scale" and node[key] == nil then
							cur = { 1, 1, 1 }
						end
					end
					cur[i] = v
					node[key] = cur
				else
					node[key] = v
				end
			end, label)
		end

		local SWATCHES = { "#a9b4c2", "#3a3d42", "#e8893a", "#4a8fe0", "#4caf6a", "#d9534f", "#e6c34a", "#d9c3a5" }

		local inspector = ui.presence(function(): string
			local d = doc()
			return `{d.selected or ""}:{d.drev}`
		end, function(): Node
			local d = docs.get(sid)
			local path = d.selected
			local node = if path and d.design then geom.at(d.design, path) else nil
			if not node then
				return ui.column {
					w_full = true,
					p = "$space.3",
					ui.text { "Click a part in the view, or in Parts, to edit it.", text_size = "$font.size.sm", color = "$text.tertiary", wrap = true },
				}
			end
			local p = path :: string
			local t = node.type
			local fields = {}
			for _, f in FIELDS[t] or {} do
				local key, index, label = f[1], f[2], f[3]
				local present = node[key] ~= nil or (ALWAYS[t] and ALWAYS[t][key])
				if t == "cylinder" and key == "r" and node.d == nil and node.r1 == nil and node.d1 == nil then
					present = true
				end
				if present then
					local cur = node[key]
					local value = if index ~= "" then (if type(cur) == "table" then cur[tonumber(index) :: number] else cur) else cur
					table.insert(fields, NumField {
						label = label,
						value = value,
						on_commit = function(v: any)
							set_field(p, key, index, v)
						end,
					})
				end
			end
			local function triple(key: string, label: string, default: number): Node
				local cur = node[key]
				local cells = {}
				for i, axis in { "X", "Y", "Z" } do
					local v = if type(cur) == "table" then cur[i] elseif cur ~= nil then cur else default
					table.insert(cells, NumField {
						label = `{label} {axis}`,
						value = v,
						on_commit = function(nv: any)
							set_field(p, key, tostring(i), nv)
						end,
					})
				end
				return ui.row { w_full = true, gap = "$space.2", table.unpack(cells) }
			end
			local top_level = string.match(p, "^body%.%d+$") ~= nil
			local mode_state = ui.use_state(node.mode or "add")
			-- (The mode, as it's chosen: the design changes with it.)
			ui.effect(function()
				local m = mode_state:get()
				local now = node.mode or "add"
				if m ~= now then
					ui.task(function()
						docs.edit(sid, function(design: any)
							local n = geom.at(design, p)
							if n then
								n.mode = if m == "add" then nil else m
							end
						end, `{node.name or node.type}: {m}`)
					end)
				end
			end)
			local name = ui.use_state(node.name or "")
			return ui.column {
				w_full = true,
				gap = "$space.3",
				px = "$space.3",
				py = "$space.2",
				ui.row {
					w_full = true,
					items = "end",
					gap = "$space.2",
					TextField {
						value = name,
						label = `Name · {t}`,
						size = "sm",
						grow = 1,
						on_commit = function(text: string)
							docs.edit(sid, function(design: any)
								local n = geom.at(design, p)
								if n then
									n.name = if text == "" then nil else text
								end
							end, `Renamed to {if text == "" then t else text}`)
						end,
					},
					ui.show(top_level, Segmented {
						value = mode_state,
						label = "How it combines",
						options = { { value = "add", label = "Add" }, { value = "cut", label = "Cut" }, { value = "intersect", label = "Intersect" } },
					}),
				},
				ui.row { w_full = true, gap = "$space.2", flex_wrap = true, table.unpack(fields) },
				triple("translate", "Move", 0),
				triple("rotate", "Turn", 0),
				ui.row {
					w_full = true,
					items = "center",
					gap = "$space.1",
					ui.text { "Colour", text_size = "$font.size.xs", color = "$text.tertiary", pr = "$space.1" },
					ui.each(SWATCHES, function(hex: string): Node
						return ui.button {
							w = 18,
							h = 18,
							rounded = 9,
							bg = hex,
							border = function(): number
								local n = geom.at(docs.get(sid).design, p)
								return if n and n.color == hex then 2 else 0
							end,
							border_color = "$accent",
							label = `Colour {hex}`,
							on_click = function()
								docs.edit(sid, function(design: any)
									local n = geom.at(design, p)
									if n then
										n.color = hex
									end
								end, `Coloured {node.name or node.type}`)
							end,
						}
					end, { direction = "row", gap = "$space.1" }),
					ui.column { grow = 1 },
					Button {
						"Duplicate",
						size = "xs",
						tone = "ghost",
						on_click = function()
							local idx = 0
							local _, parent, at = geom.at(docs.get(sid).design, p)
							if not parent or not at then
								return
							end
							docs.edit(sid, function(design: any)
								local _, list, i = geom.at(design, p)
								if list and i then
									local copy = docs.clone(list[i])
									copy.name = (copy.name or copy.type) .. " copy"
									local tr = if type(copy.translate) == "table" then copy.translate else { 0, 0, 0 }
									if type(tr[1]) == "number" then
										tr[1] += 10
									end
									copy.translate = tr
									table.insert(list, i + 1, copy)
									idx = i + 1
								end
							end, `Duplicated {node.name or node.type}`)
							local base = string.match(p, "^(.*)%.%d+$")
							if base and idx > 0 then
								docs.select(sid, `{base}.{idx}`)
							end
						end,
					},
					Button {
						"Delete",
						size = "xs",
						tone = "danger",
						on_click = function()
							docs.edit(sid, function(design: any)
								local _, list, i = geom.at(design, p)
								if list and i then
									table.remove(list, i)
								end
							end, `Deleted {node.name or node.type}`)
							docs.select(sid, nil)
						end,
					},
				},
			}
		end, { w_full = true })


		-- When something is picked, show it.
		local last_selected: string? = docs.get(sid).selected
		ui.effect(function()
			local d = doc()
			if d.selected ~= last_selected then
				last_selected = d.selected
				if d.selected then
					sheet:set("part")
				end
			end
		end)

		-- History and variants ----------------------------------------------------

		local function ago(at: number?): string
			local secs = os.time() - (at or os.time())
			if secs < 45 then
				return "just now"
			elseif secs < 3600 then
				return `{math.max(1, math.floor(secs / 60 + 0.5))} min ago`
			elseif secs < 86400 then
				return `{math.floor(secs / 3600 + 0.5)} h ago`
			end
			return `{math.floor(secs / 86400 + 0.5)} d ago`
		end

		local function ask_variations()
			sheet:set("variants")
			zeron.compose("In the CAD design: propose 4 distinct variations of this design with propose_variants (different styles, proportions or features), each with a short label.")
			zeron.toast("In the message box: press Return to send it")
		end

		-- A small view of a mesh (a past version's, a variant's), framed from
		-- the angle the main view starts at.
		local function Thumb(get: () -> any, h: number): Node
			local tf = render.frame()
			return ui.canvas {
				w_full = true,
				h = h,
				rounded = 6,
				bg = "$hover",
				label = "Preview",
				draw = function(c: any, w: number, hh: number)
					docs.tick:get()
					local e = get()
					if not e or not e.mesh then
						local word = if e and e.status == "error" then "Didn't build" else "…"
						c:text(word, w / 2, hh / 2, { size = 11, color = "$text.tertiary", align = "center", baseline = "middle" })
						return
					end
					local cam = render.fit(render.camera(), e.bounds)
					render.draw(c, w, hh, { mesh = e.mesh, cam = cam, look = render.look(dark()), bounds = e.bounds, frame = tf, grid = false, triad = false })
				end,
			}
		end

		-- (A preview the pointer brought goes as it leaves; one clicked stays
		-- until Back to current, or another is clicked.)
		local function unpreview(match: (pv: any) -> boolean)
			local pv = preview:peek()
			if pv and not pv.pinned and match(pv) then
				preview:set(nil)
			end
		end
		local function hover_preview(pv: any)
			local now = preview:peek()
			if now and now.pinned then
				return
			end
			preview:set(pv)
		end
		local function pin_preview(pv: any)
			local now = preview:peek()
			local same = now and now.kind == pv.kind and now.i == pv.i and now.snap == pv.snap
			if same and now.pinned then
				preview:set(nil)
			else
				local pinned = table.clone(pv)
				pinned.pinned = true
				preview:set(pinned)
			end
		end

		-- Every change, newest first: point at one to see it in the view,
		-- Restore to put it back (as a new change).
		local history = ui.presence(function(): string
			local d = doc()
			return `{#d.history}:{d.rev}`
		end, function(): Node
			local d = docs.get(sid)
			local list = d.history
			if #list == 0 then
				return ui.column {
					w_full = true,
					p = "$space.3",
					ui.text {
						"Each change, yours and the agent's, shows here. Point at one to see it in the view; Restore puts it back.",
						text_size = "$font.size.sm",
						color = "$text.tertiary",
						wrap = true,
					},
				}
			end
			local current = if d.design then docs.encode({ design = d.design, values = d.values }) else ""
			local rows = {}
			for i = #list, 1, -1 do
				local h = list[i]
				-- (The newest five get pictures; the rest build as they're pointed at.)
				local pictured = #list - i < 5
				if pictured then
					docs.preview(h.snap)
				end
				local is_current = h.snap == current
				local this = { kind = "history", snap = h.snap, label = h.label }
				table.insert(rows, ListRow {
					label = h.label,
					selected = function(): boolean
						return is_current
					end,
					on_click = function()
						if not is_current then
							pin_preview(this)
						end
					end,
					ui.row {
						on_hover = function(inside: boolean)
							if inside and not is_current then
								hover_preview(this)
							else
								unpreview(function(pv)
									return pv.kind == "history" and pv.snap == h.snap
								end)
							end
						end,
						w_full = true,
						items = "center",
						gap = "$space.2",
						px = "$space.3",
						py = "$space.1",
						ui.column {
							w = 68,
							if pictured
								then Thumb(function()
									return docs.preview(h.snap)
								end, 48)
								else ui.column {
									w_full = true,
									h = 48,
									rounded = 6,
									bg = "$hover",
									items = "center",
									justify = "center",
									ui.text { `v{i}`, text_size = "$font.size.xs", color = "$text.tertiary" },
								},
						},
						ui.column {
							grow = 1,
							gap = 2,
							ui.text { h.label, text_size = "$font.size.sm", color = "$text.primary", truncate = true },
							ui.text {
								`{if h.by == "ai" then "Agent" else "You"} · {ago(h.at)}{if is_current then " · now showing" else ""}`,
								text_size = "$font.size.xs",
								color = if h.by == "ai" then "$accent" else "$text.tertiary",
							},
						},
						ui.show(not is_current, Button {
							"Restore",
							size = "xs",
							tone = "ghost",
							on_click = function()
								preview:set(nil)
								docs.restore_version(sid, i)
							end,
						}),
					},
				})
			end
			return ui.column { w_full = true, py = "$space.1", table.unpack(rows) }
		end, { w_full = true })

		-- Takes on the design the agent proposed: point at one to see it in
		-- the view, Use to adopt it.
		local variants = ui.presence(function(): string
			local d = doc()
			local key = {}
			for _, v in d.variants do
				table.insert(key, `{v.round}:{v.status}:{if v.adopted then 1 else 0}`)
			end
			return table.concat(key, ",")
		end, function(): Node
			local d = docs.get(sid)
			if #d.variants == 0 then
				return ui.column {
					w_full = true,
					p = "$space.3",
					gap = "$space.2",
					ui.text {
						"Ask the agent for variations and they line up here side by side. Point at one to see it in the view, and Use the one you like.",
						text_size = "$font.size.sm",
						color = "$text.tertiary",
						wrap = true,
					},
					ui.row { Button { "Ask for 4 variations", size = "sm", tone = "secondary", on_click = ask_variations } },
				}
			end
			local tiles = {}
			for i, v in d.variants do
				table.insert(tiles, ui.column {
					w = "48%",
					gap = "$space.1",
					p = "$space.2",
					rounded = 10,
					border = 1,
					border_color = if v.adopted then "$accent" else "$border",
					on_click = function()
						if v.status == "ready" then
							pin_preview({ kind = "variant", i = i })
						end
					end,
					on_hover = function(inside: boolean)
						if inside then
							hover_preview({ kind = "variant", i = i })
						else
							unpreview(function(pv)
								return pv.kind == "variant" and pv.i == i
							end)
						end
					end,
					Thumb(function()
						return docs.get(sid).variants[i]
					end, 110),
					ui.row {
						w_full = true,
						items = "center",
						gap = "$space.1",
						ui.text { v.label, text_size = "$font.size.sm", color = "$text.primary", truncate = true, grow = 1 },
						if v.status == "error"
							then ui.text { "Didn't build", text_size = "$font.size.xs", color = "$danger" }
							else Button {
								if v.adopted then "In use" else "Use",
								size = "xs",
								tone = if v.adopted then "ghost" else "accent",
								disabled = v.status ~= "ready",
								on_click = function()
									preview:set(nil)
									docs.use_variant(sid, i)
								end,
							},
					},
					ui.show(type(v.note) == "string" and v.note ~= "", ui.text {
						if type(v.note) == "string" then v.note else "",
						text_size = "$font.size.xs",
						color = "$text.tertiary",
						wrap = true,
					}),
				})
			end
			return ui.column {
				w_full = true,
				gap = "$space.2",
				px = "$space.3",
				py = "$space.2",
				ui.row { w_full = true, flex_wrap = true, gap = "$space.2", table.unpack(tiles) },
				ui.row {
					gap = "$space.1",
					Button { "More variations", size = "xs", tone = "secondary", on_click = ask_variations },
					Button {
						"Clear",
						size = "xs",
						tone = "ghost",
						on_click = function()
							preview:set(nil)
							docs.clear_variants(sid)
						end,
					},
				},
			}
		end, { w_full = true })

		-- New variants from the agent: show them.
		local last_round: any = false
		ui.effect(function()
			local d = doc()
			local r = d.variants[1] and d.variants[1].round
			if r ~= last_round then
				local first = last_round == false
				last_round = r
				if r and not first then
					sheet:set("variants")
				end
			end
		end)

		-- The bottom panel's height: dragged at the divider over it (the
		-- viewport takes the rest, 160 at least), folded to its tabs and back
		-- with a double click, and kept for next time.
		local SHEET_FOLDED, SHEET_MIN, SHEET_DEFAULT = 44, 96, 300
		local kept_h = zeron.store("sheet_h", SHEET_DEFAULT)
		local sheet_h = ui.use_state(tonumber(kept_h:peek()) or SHEET_DEFAULT)
		local unfolded_h = math.max(SHEET_MIN, sheet_h:peek())
		local root = ui.ref()
		local grip_over = ui.use_state(false)
		local grip_drag = ui.use_state(false)
		local from_y, from_h = 0, 0
		local function max_h(): number
			local total = root.height or 0
			if total <= 0 then
				return 640
			end
			-- (The header, the tools and the ask line take about 140.)
			return math.max(SHEET_MIN, total - 160 - 140)
		end
		local function height(): number
			return math.clamp(sheet_h:get(), SHEET_FOLDED, max_h())
		end
		local function set_height(h: number)
			-- (Dragged under the least that shows a row, it folds.)
			if h < SHEET_MIN then
				h = if h < (SHEET_MIN + SHEET_FOLDED) / 2 then SHEET_FOLDED else SHEET_MIN
			end
			sheet_h:set(math.clamp(h, SHEET_FOLDED, max_h()))
		end
		local function keep()
			local h = sheet_h:peek()
			if h > SHEET_FOLDED then
				unfolded_h = h
			end
			kept_h:set(h)
		end

		-- A tab chosen (by a click, or by what just happened: a selection,
		-- new variants) opens a folded panel.
		local last_sheet = sheet:peek()
		ui.effect(function()
			local now = sheet:get()
			if now ~= last_sheet then
				last_sheet = now
				if sheet_h:peek() <= SHEET_FOLDED + 0.5 then
					set_height(math.max(unfolded_h, 260))
					kept_h:set(sheet_h:peek())
				end
			end
		end)

		local divider = ui.div {
			w_full = true,
			h = 9,
			relative = true,
			cursor = "row_resize",
			label = "Resize the panel",
			tooltip = "Drag to resize · double-click to fold",
			on_hover = function(inside: boolean)
				grip_over:set(inside)
			end,
			on_press = function(e: any)
				from_y = e.y
				from_h = math.clamp(sheet_h:peek(), SHEET_FOLDED, max_h())
				grip_drag:set(true)
			end,
			on_pointer_move = function(e: any)
				if grip_drag:peek() then
					set_height(from_h - (e.y - from_y))
				end
			end,
			on_release = function()
				if grip_drag:peek() then
					grip_drag:set(false)
					keep()
				end
			end,
			on_double_click = function()
				if sheet_h:peek() <= SHEET_FOLDED + 0.5 then
					set_height(math.max(unfolded_h, 260))
				else
					unfolded_h = sheet_h:peek()
					sheet_h:set(SHEET_FOLDED)
				end
				kept_h:set(sheet_h:peek())
			end,
			-- A hairline across, firmer under the pointer and while dragged…
			ui.div {
				absolute = true,
				left = 0,
				right = 0,
				top = 4,
				h = 1,
				pointer_events = "none",
				bg = function(): string
					return if grip_over:get() or grip_drag:get() then "$border.strong" else "$border"
				end,
			},
			-- …and a grip in its middle.
			ui.row {
				absolute = true,
				left = 0,
				right = 0,
				top = 2,
				justify = "center",
				pointer_events = "none",
				ui.div {
					w = 32,
					h = 5,
					rounded = 3,
					bg = function(): string
						return if grip_drag:get() then "$accent" elseif grip_over:get() then "$text.tertiary" else "$border.strong"
					end,
				},
			},
		}

		local sheet_view = ui.column {
			w_full = true,
			h = height,
			overflow = "hidden",
			ui.row {
				w_full = true,
				px = "$space.3",
				pt = "$space.2",
				pb = "$space.1",
				Segmented {
					value = sheet,
					label = "Panel",
					options = {
						{ value = "params", label = "Parameters" },
						{ value = "parts", label = "Parts" },
						{
							value = "part",
							label = function(): string
								local p = selected_part()
								return if p then (p.name or p.type) else "Selected"
							end,
						},
						{ value = "history", label = "History" },
						{
							value = "variants",
							label = function(): string
								local n = #doc().variants
								return if n > 0 then `Variants ({n})` else "Variants"
							end,
						},
					},
				},
			},
			ui.scroll {
				w_full = true,
				grow = 1,
				scrollbar = true,
				ui.switch(sheet, {
					params = params,
					parts = parts,
					part = inspector,
					history = history,
					variants = variants,
				}),
			},
		}

		local ask_row = ui.row {
			w_full = true,
			items = "center",
			gap = "$space.2",
			px = "$space.3",
			py = "$space.2",
			border_sides = { 1, 0, 0, 0 },
			border_color = "$border",
			TextField {
				value = ask,
				placeholder = function(): string
					local p = selected_part()
					return if p then `Ask the agent to change "{p.name or p.type}"…` else "Ask the agent for a design or a change…"
				end,
				icon = "magic-stick",
				size = "sm",
				grow = 1,
				on_commit = function()
					send_ask()
				end,
			},
			Button { "Ask", size = "sm", tone = "accent", on_click = send_ask },
		}

		return ui.column {
			ref = root,
			w_full = true,
			h_full = true,
			gap = 0,
			header,
			tools,
			viewport,
			divider,
			sheet_view,
			ask_row,
		}
	end)

	return Tab
end
