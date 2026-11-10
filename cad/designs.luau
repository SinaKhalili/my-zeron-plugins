-- Each chat's design: the document (plain data), the person's parameter
-- values, its history (undo, redo), and its built mesh. Kept in the
-- plugin's database, built in slices (a task that yields between them), so
-- a heavy boolean never stalls the window or runs past a call's budget.

local csg = require("./csg")
local geom = require("./geom")

return function(zeron: any)
	local M = {}

	-- One counter for every change (a design, a build, a selection): what
	-- reads it draws again. The data itself stays in plain tables.
	local tick = ui.state("cad.tick", 0)
	M.tick = tick
	local function bump()
		tick:set(tick:peek() + 1)
	end
	M.bump = bump

	export type Doc = {
		design: any?,
		values: { [string]: any },
		rev: number,
		undo: { string },
		redo: { string },
		loaded: boolean,
		-- Build: what was built, from which rev.
		built: number,
		status: string, -- "empty" | "building" | "ready" | "error"
		error: string?,
		mesh: any?,
		polys: any?,
		parts: { any },
		warnings: { string },
		bounds: { number }?,
		ms: number?,
		task: any?,
		-- What the mouse picked (a part's path).
		selected: string?,
		-- Asked to open its tab (by an agent's change).
		open_asked: boolean,
		-- The design's own revision (not its values'): what lists of its
		-- parameters and parts are built from.
		drev: number,
		-- Frame it once it's built (a new design, an example).
		want_fit: boolean,
		again: boolean,
		-- Every change, newest last: { snap, label, by ("you" | "ai"), at }.
		history: { any },
		hseq: number,
		-- The face the mouse last pointed at: { point, normal, path }.
		pick: any?,
		-- Takes on the design an agent proposed: { label, note, design,
		-- values, status, mesh, bounds, error }.
		variants: { any },
		-- The section and the exploded view, built on demand.
		section: any?,
		exploded: any?,
	}

	local docs: { [string]: Doc } = {}

	zeron.db.exec([[
		CREATE TABLE IF NOT EXISTS designs (session TEXT PRIMARY KEY, design TEXT, vals TEXT, updated INTEGER);
		CREATE TABLE IF NOT EXISTS history (session TEXT, seq INTEGER, label TEXT, who TEXT, at INTEGER, snap TEXT, PRIMARY KEY (session, seq));
	]])
	local HISTORY = 60

	local function encode(v: any): string
		return ui.json.encode(v)
	end
	local function decode(s: string?): any
		if type(s) ~= "string" or s == "" then
			return nil
		end
		local ok, v = pcall(ui.json.decode, s)
		return if ok then v else nil
	end
	local function clone(v: any): any
		if v == nil then
			return nil
		end
		return decode(encode(v))
	end
	M.clone = clone

	local build: (sid: string, doc: Doc) -> ()

	function M.get(sid: string): Doc
		local doc = docs[sid]
		if doc then
			return doc
		end
		doc = {
			design = nil,
			values = {},
			rev = 0,
			undo = {},
			redo = {},
			loaded = false,
			built = -1,
			status = "empty",
			parts = {},
			warnings = {},
			open_asked = false,
			drev = 0,
			want_fit = true,
			again = false,
			history = {},
			hseq = 0,
			variants = {},
		}
		docs[sid] = doc
		zeron.db.query("SELECT design, vals FROM designs WHERE session = ?", { sid }):after(function(rows: any)
			local row = rows and rows[1]
			-- (A change made while it loaded wins.)
			if row and doc.rev == 0 then
				doc.design = decode(row.design)
				doc.values = decode(row.vals) or {}
				doc.rev = 1
				doc.drev = 1
			end
			-- Then its history (a change made meanwhile stays the newest).
			zeron.db.query("SELECT seq, label, who, at, snap FROM history WHERE session = ? ORDER BY seq DESC LIMIT ?", { sid, HISTORY }):after(function(hrows: any)
				local older = {}
				for i = #(hrows or {}), 1, -1 do
					local h = hrows[i]
					table.insert(older, { snap = h.snap, label = h.label, by = h.who, at = h.at })
					doc.hseq = math.max(doc.hseq, h.seq or 0)
				end
				for _, h in doc.history do
					table.insert(older, h)
				end
				doc.history = older
				if #doc.history == 0 and doc.design ~= nil then
					M.record(sid, "Current design", "you")
				end
				bump()
			end)
			doc.loaded = true
			build(sid, doc)
			bump()
		end, function(err: any)
			print(`cad: couldn't read the design: {err}`)
			doc.loaded = true
			bump()
		end)
		return doc
	end

	local function save(sid: string, doc: Doc)
		if doc.design == nil then
			zeron.db.exec("DELETE FROM designs WHERE session = ?", { sid })
		else
			zeron.db.exec(
				"INSERT OR REPLACE INTO designs VALUES (?, ?, ?, ?)",
				{ sid, encode(doc.design), encode(doc.values), os.time() }
			)
		end
	end

	-- Mesh ------------------------------------------------------------------

	local function hex_rgb(s: string?): { number }?
		if type(s) ~= "string" then
			return nil
		end
		local h = string.match(s, "^#?(%x%x%x%x%x%x)")
		if h then
			return { tonumber(string.sub(h, 1, 2), 16) / 255, tonumber(string.sub(h, 3, 4), 16) / 255, tonumber(string.sub(h, 5, 6), 16) / 255 }
		end
		local s3 = string.match(s, "^#?(%x%x%x)$")
		if s3 then
			return {
				tonumber(string.sub(s3, 1, 1), 16) / 15,
				tonumber(string.sub(s3, 2, 2), 16) / 15,
				tonumber(string.sub(s3, 3, 3), 16) / 15,
			}
		end
		return nil
	end
	M.hex_rgb = hex_rgb

	local NAMED: { [string]: string } = {
		red = "#d9534f", green = "#4caf6a", blue = "#4a8fe0", yellow = "#e6c34a", orange = "#e8893a",
		purple = "#9a6fd6", pink = "#e07aa8", white = "#eef0f2", black = "#2c3036", gray = "#9aa3ad",
		grey = "#9aa3ad", silver = "#c3c9cf", gold = "#d4a843", brown = "#8b6a4f", teal = "#3fa7a0",
		cyan = "#4cc3d9", wood = "#c49a6c", steel = "#a7b1bc", aluminium = "#c9cfd6", aluminum = "#c9cfd6",
		brass = "#c9a24a", copper = "#c27a4a", rubber = "#3a3d42", plastic = "#e8e8e3",
		-- (A section's cut faces.)
		cap = "#ff6a3d",
	}

	-- The solid's creases: sides between two of its faces turned 20° or more
	-- apart (and sides more than two faces share), as segments.
	local function creases(polys: { any }): { any }
		local index: { [string]: number } = {}
		local at: { { number } } = {}
		local function corner(q: { number }): number
			local key = `{math.floor(q[1] * 1e4 + 0.5)},{math.floor(q[2] * 1e4 + 0.5)},{math.floor(q[3] * 1e4 + 0.5)}`
			local i = index[key]
			if not i then
				table.insert(at, q)
				i = #at
				index[key] = i
			end
			return i
		end
		local sides: { [number]: any } = {}
		local count = 0
		for _, p in polys do
			local n = #p.v
			local ids = table.create(n)
			for k, q in p.v do
				ids[k] = corner(q)
			end
			for k = 1, n do
				local a, b = ids[k], ids[(k % n) + 1]
				if a ~= b then
					local key = math.min(a, b) * 4194304 + math.max(a, b)
					local list = sides[key]
					if not list then
						list = {}
						sides[key] = list
					end
					table.insert(list, { a, b, p.nx, p.ny, p.nz })
				end
			end
			count += 1
			if count % 64 == 0 then
				csg.pause()
			end
		end
		local crease = math.cos(math.rad(20))
		local out = {}
		for _, list in sides do
			local edge = false
			if #list == 2 then
				local a, b = list[1], list[2]
				edge = a[3] * b[3] + a[4] * b[4] + a[5] * b[5] < crease
			elseif #list > 2 then
				edge = true
			end
			if edge then
				table.insert(out, { at[list[1][1]], at[list[1][2]] })
			end
		end
		return out
	end

	-- What the viewport draws: the solid's polygons in a view tree (split
	-- where they cross its planes), as an indexed mesh of triangles (fans of
	-- each piece) with their face's normal, colour and part, each node's
	-- plane, children and range of triangles, and the creases' segments
	-- placed at the nodes they lie on.
	local function mesh_of(polys: { any }): any
		local segs = creases(polys)
		local root = csg.view_tree(polys)
		for i, s in segs do
			csg.place_segment(root, s[1], s[2])
			if i % 64 == 0 then
				csg.pause()
			end
		end
		local vx, vy, vz = {}, {}, {}
		local index: { [string]: number } = {}
		local function corner(q: { number }): number
			local key = `{math.floor(q[1] * 1e4 + 0.5)},{math.floor(q[2] * 1e4 + 0.5)},{math.floor(q[3] * 1e4 + 0.5)}`
			local i = index[key]
			if not i then
				table.insert(vx, q[1])
				table.insert(vy, q[2])
				table.insert(vz, q[3])
				i = #vx
				index[key] = i
			end
			return i
		end
		local tri, tn, tc, tp = {}, {}, {}, {}
		local colors: { { number } } = {}
		local color_index: { [string]: number } = {}
		local function color_of(cname: string?): number
			if not cname then
				return 0
			end
			local ci = color_index[cname]
			if ci then
				return ci
			end
			local rgb = hex_rgb(NAMED[string.lower(cname)] or cname)
			ci = 0
			if rgb then
				table.insert(colors, rgb)
				ci = #colors
			end
			color_index[cname] = ci
			return ci
		end
		-- Nodes, numbered depth first from 1 (the root).
		local np, nf, nb, nt0, nt1, ns0, ns1 = {}, {}, {}, {}, {}, {}, {}
		local sa, sb = {}, {}
		local order: { any } = {}
		local number: { [any]: number } = {}
		local walk = { root }
		while #walk > 0 do
			local nd = table.remove(walk)
			table.insert(order, nd)
			number[nd] = #order
			if nd.back then
				table.insert(walk, nd.back)
			end
			if nd.front then
				table.insert(walk, nd.front)
			end
		end
		for i, nd in order do
			local pl = nd.plane or { 0, 0, 1, 0 }
			np[i * 4 - 3], np[i * 4 - 2], np[i * 4 - 1], np[i * 4] = pl[1], pl[2], pl[3], pl[4]
			nf[i] = if nd.front then number[nd.front] else 0
			nb[i] = if nd.back then number[nd.back] else 0
			nt0[i] = #tc + 1
			for _, p in nd.polys do
				local n = #p.v
				local ids = table.create(n)
				for k, q in p.v do
					ids[k] = corner(q)
				end
				local ci = color_of(p.color)
				for k = 2, n - 1 do
					local a, b, c = ids[1], ids[k], ids[k + 1]
					if a ~= b and b ~= c and a ~= c then
						table.insert(tri, a)
						table.insert(tri, b)
						table.insert(tri, c)
						table.insert(tn, p.nx)
						table.insert(tn, p.ny)
						table.insert(tn, p.nz)
						table.insert(tc, ci)
						table.insert(tp, p.part or 0)
					end
				end
			end
			nt1[i] = #tc
			ns0[i] = #sa + 1
			for _, s in nd.segs or {} do
				table.insert(sa, corner(s[1]))
				table.insert(sb, corner(s[2]))
			end
			ns1[i] = #sa
			if i % 64 == 0 then
				csg.pause()
			end
		end
		return {
			vx = vx, vy = vy, vz = vz,
			tri = tri, tn = tn, tc = tc, tp = tp,
			colors = colors,
			triangles = #tc,
			nodes = #order,
			np = np, nf = nf, nb = nb, nt0 = nt0, nt1 = nt1, ns0 = ns0, ns1 = ns1,
			sa = sa, sb = sb,
		}
	end

	-- Builds ----------------------------------------------------------------

	local SLICE = 0.012
	local slice_start = 0
	local function yielding()
		if os.clock() - slice_start > SLICE then
			ui.sleep(1):await()
			slice_start = os.clock()
		end
	end
	-- (Every geometry job runs in a task, so the engine may always yield.
	-- Each task notes when it starts, and each resumes from an await.)
	csg.pause = yielding

	-- What's told of a change: what reads the counter draws again. (What a
	-- reader does wrong is its own: a build goes on.)
	local function tell()
		local ok, why = pcall(bump)
		if not ok then
			print(`cad: a view failed on a change: {why}`)
		end
	end

	-- One build at a time per design. A change while one runs builds again
	-- once it's done, from the latest: a slider dragged through many values
	-- shows each build as it lands, and never a stale one after.
	--
	-- The running build is a token of its own, set before its task starts: a
	-- small design builds without yielding, so its task can finish before
	-- `ui.task` even returns.
	build = function(sid: string, doc: Doc)
		if doc.built == doc.rev and doc.status ~= "building" then
			return
		end
		if doc.task then
			-- (One that's been running far too long has died: start over.)
			if os.clock() - (doc.task.started or 0) < 30 then
				doc.again = true
				return
			end
			doc.task = nil
		end
		if doc.design == nil then
			doc.status = "empty"
			doc.mesh, doc.polys, doc.parts, doc.bounds, doc.error = nil, nil, {}, nil, nil
			doc.built = doc.rev
			tell()
			return
		end
		local rev = doc.rev
		local design, values = doc.design, doc.values
		local token = { started = os.clock() }
		doc.task = token
		doc.status = "building"
		tell()
		ui.task(function()
			local started = os.clock()
			slice_start = os.clock()
			local ok, result = pcall(function()
				local r = geom.build(design, values)
				local mesh = mesh_of(r.polys)
				return { r = r, mesh = mesh }
			end)
			if doc.task ~= token then
				-- (Given up on: a newer build owns the design.)
				return
			end
			doc.task = nil
			doc.built = rev
			if ok then
				doc.status = "ready"
				doc.error = nil
				doc.polys = result.r.polys
				doc.parts = result.r.parts
				doc.warnings = result.r.warnings
				doc.mesh = result.mesh
				doc.bounds = csg.bounds(result.r.polys)
				if #result.r.polys == 0 then
					table.insert(doc.warnings, "The design is empty: nothing is left after its cuts.")
				end
			else
				doc.status = "error"
				doc.error = tostring(result)
				-- (The last good mesh stays on screen under the error.)
			end
			doc.ms = math.floor((os.clock() - started) * 1000)
			doc.again = false
			if doc.rev ~= rev then
				-- (Changed meanwhile: build the latest now.)
				build(sid, doc)
				return
			end
			tell()
		end)
	end
	M.build = build

	-- Waits (in a task) until the session's design is built: true if it is.
	function M.settle(sid: string, timeout: number?): boolean
		local doc = M.get(sid)
		local limit = os.clock() + (timeout or 8)
		while not doc.loaded or doc.status == "building" or doc.built ~= doc.rev do
			if os.clock() > limit then
				return false
			end
			if doc.loaded and doc.built ~= doc.rev and doc.task == nil then
				build(sid, doc)
			end
			ui.sleep(30):await()
		end
		return true
	end

	-- Changes -----------------------------------------------------------------

	local function snapshot(doc: Doc): string
		return encode({ design = doc.design, values = doc.values })
	end

	-- A history entry for the design as it is now.
	function M.record(sid: string, label: string, by: string?)
		local doc = M.get(sid)
		if doc.design == nil then
			return
		end
		local entry = { snap = snapshot(doc), label = label, by = by or "you", at = os.time() }
		local last = doc.history[#doc.history]
		if last and last.snap == entry.snap then
			return
		end
		table.insert(doc.history, entry)
		while #doc.history > HISTORY do
			table.remove(doc.history, 1)
		end
		doc.hseq += 1
		zeron.db.exec("INSERT OR REPLACE INTO history VALUES (?, ?, ?, ?, ?, ?)", { sid, doc.hseq, entry.label, entry.by, entry.at, entry.snap })
		zeron.db.exec("DELETE FROM history WHERE session = ? AND seq <= ?", { sid, doc.hseq - HISTORY })
	end

	-- A new design (or a changed one), undoable, with what it was for the
	-- history.
	function M.set(sid: string, design: any, values: { [string]: any }?, keep_values: boolean?, label: string?, by: string?)
		local doc = M.get(sid)
		table.insert(doc.undo, snapshot(doc))
		if #doc.undo > 60 then
			table.remove(doc.undo, 1)
		end
		doc.redo = {}
		doc.design = design
		if values then
			doc.values = values
		elseif not keep_values then
			-- Values the new design still has a parameter for stay.
			local kept = {}
			for _, p in (if design and type(design.params) == "table" then design.params else {}) :: { any } do
				if type(p) == "table" and p.id ~= nil and doc.values[p.id] ~= nil then
					kept[p.id] = doc.values[p.id]
				end
			end
			doc.values = kept
		end
		doc.rev += 1
		doc.drev += 1
		if doc.selected and design and geom.at(design, doc.selected) == nil then
			doc.selected = nil
		end
		doc.pick = nil
		save(sid, doc)
		M.record(sid, label or "Changed the design", by)
		build(sid, doc)
		bump()
	end

	-- A change to the design in place: `fn(copy)` edits a copy.
	function M.edit(sid: string, fn: (design: any) -> (), label: string?, by: string?)
		local doc = M.get(sid)
		local copy = clone(doc.design) or { name = "Untitled", params = {}, body = {} }
		fn(copy)
		M.set(sid, copy, nil, true, label, by)
	end

	local function param_label(doc: Doc, id: string): string
		for _, p in (if doc.design and type(doc.design.params) == "table" then doc.design.params else {}) :: { any } do
			if type(p) == "table" and p.id == id then
				return p.label or id
			end
		end
		return id
	end
	local function shown(v: any): string
		if type(v) == "number" then
			local r = math.floor(v * 100 + 0.5) / 100
			return if r == math.floor(r) then tostring(math.floor(r)) else tostring(r)
		elseif type(v) == "boolean" then
			return if v then "on" else "off"
		end
		return tostring(v)
	end
	local function now_value(doc: Doc, id: string): any
		local v = doc.values[id]
		if v ~= nil then
			return v
		end
		for _, p in (if doc.design and type(doc.design.params) == "table" then doc.design.params else {}) :: { any } do
			if type(p) == "table" and p.id == id then
				return p.value
			end
		end
		return nil
	end

	-- A parameter's value as the person drags it: one undo step a drag
	-- (`commit` closes it).
	-- (What each value was as the drag began, for its history entry.)
	local dragging: { [string]: { [string]: any } } = {}
	local function drag_label(doc: Doc, from: { [string]: any }): string
		local parts = {}
		for id, was in from do
			table.insert(parts, `{param_label(doc, id)} {shown(was)} → {shown(now_value(doc, id))}`)
		end
		table.sort(parts)
		return table.concat(parts, ", ")
	end
	function M.set_value(sid: string, id: string, value: any, commit: boolean?)
		local doc = M.get(sid)
		if not dragging[sid] then
			table.insert(doc.undo, snapshot(doc))
			doc.redo = {}
			dragging[sid] = {}
		end
		local from = dragging[sid] :: { [string]: any }
		if from[id] == nil then
			from[id] = now_value(doc, id)
		end
		local values = table.clone(doc.values)
		values[id] = value
		doc.values = values
		-- (The face pointed at may not be there any more.)
		doc.pick = nil
		doc.rev += 1
		build(sid, doc)
		bump()
		if commit ~= false then
			M.end_drag(sid)
		end
	end
	-- Values set from outside the sliders (an agent's): one undo step, and
	-- the sliders are built again to show them.
	function M.set_values(sid: string, values: { [string]: any }, by: string?)
		local doc = M.get(sid)
		table.insert(doc.undo, snapshot(doc))
		doc.redo = {}
		local from = {}
		for k in values do
			from[k] = now_value(doc, k)
		end
		local merged = table.clone(doc.values)
		for k, v in values do
			merged[k] = v
		end
		doc.values = merged
		doc.rev += 1
		doc.drev += 1
		save(sid, doc)
		M.record(sid, drag_label(doc, from), by)
		build(sid, doc)
		bump()
	end

	function M.end_drag(sid: string)
		local from = dragging[sid]
		if from then
			dragging[sid] = nil
			local doc = M.get(sid)
			save(sid, doc)
			M.record(sid, drag_label(doc, from), "you")
		end
	end

	local function restore(sid: string, doc: Doc, from: { string }, to: { string })
		local s = table.remove(from)
		if not s then
			return
		end
		table.insert(to, snapshot(doc))
		local v = decode(s) or {}
		doc.design = v.design
		doc.values = v.values or {}
		doc.rev += 1
		doc.drev += 1
		if doc.selected and (doc.design == nil or geom.at(doc.design, doc.selected) == nil) then
			doc.selected = nil
		end
		doc.pick = nil
		save(sid, doc)
		build(sid, doc)
		bump()
	end
	function M.undo(sid: string)
		local doc = M.get(sid)
		restore(sid, doc, doc.undo, doc.redo)
	end
	function M.redo(sid: string)
		local doc = M.get(sid)
		restore(sid, doc, doc.redo, doc.undo)
	end

	function M.select(sid: string, path: string?)
		local doc = M.get(sid)
		if doc.selected ~= path then
			doc.selected = path
			if not path then
				doc.pick = nil
			end
			bump()
		end
	end

	-- The face the mouse pointed at, for point-and-ask: where on it, which
	-- way it faces, and its part.
	function M.pick(sid: string, pick: any?)
		local doc = M.get(sid)
		doc.pick = pick
		bump()
	end

	-- Which way a face looks, in words.
	function M.facing(n: { number }): string
		local x, y, z = n[1], n[2], n[3]
		if z > 0.9 then
			return "top"
		elseif z < -0.9 then
			return "bottom"
		elseif x > 0.9 then
			return "right (+X)"
		elseif x < -0.9 then
			return "left (−X)"
		elseif y > 0.9 then
			return "back (+Y)"
		elseif y < -0.9 then
			return "front (−Y)"
		end
		return if z > 0.3 then "upward-sloping" elseif z < -0.3 then "downward-sloping" else "angled side"
	end

	function M.ask_open(sid: string)
		M.get(sid).open_asked = true
		bump()
	end

	-- The part a path names (from the last build).
	function M.part(doc: Doc, path: string?): any
		if not path then
			return nil
		end
		for _, p in doc.parts do
			if p.path == path then
				return p
			end
		end
		return nil
	end

	-- What an agent reads of a build.
	function M.summary(doc: Doc): any
		local parts = {}
		for _, p in doc.parts do
			table.insert(parts, { path = p.path, name = p.name, type = p.type, mode = p.mode })
		end
		local b = doc.bounds
		return {
			status = doc.status,
			error = doc.error,
			warnings = doc.warnings,
			triangles = if doc.mesh then doc.mesh.triangles else 0,
			bounds = if b then { min = { b[1], b[2], b[3] }, max = { b[4], b[5], b[6] }, size = { b[4] - b[1], b[5] - b[2], b[6] - b[3] } } else nil,
			parts = parts,
			build_ms = doc.ms,
		}
	end

	-- ASCII STL of the built solid.
	function M.stl(doc: Doc, name: string): string?
		local polys = doc.polys
		if not polys or #polys == 0 then
			return nil
		end
		local out = { `solid {name}` }
		local f = function(x: number): string
			return string.format("%.6g", x)
		end
		for _, p in polys do
			local v = p.v
			local normal = `  facet normal {f(p.nx)} {f(p.ny)} {f(p.nz)}`
			for k = 2, #v - 1 do
				local a, b, c = v[1], v[k], v[k + 1]
				table.insert(out, normal)
				table.insert(out, "    outer loop")
				table.insert(out, `      vertex {f(a[1])} {f(a[2])} {f(a[3])}`)
				table.insert(out, `      vertex {f(b[1])} {f(b[2])} {f(b[3])}`)
				table.insert(out, `      vertex {f(c[1])} {f(c[2])} {f(c[3])}`)
				table.insert(out, "    endloop")
				table.insert(out, "  endfacet")
			end
		end
		table.insert(out, `endsolid {name}`)
		return table.concat(out, "\n")
	end

	-- Background work -----------------------------------------------------------
	-- Section cuts, exploded pieces, variants and previews of past versions:
	-- one job at a time, in a task of its own, each in slices as builds are.
	-- A job queued again under the same key replaces the waiting one.

	local queue: { { key: string, run: () -> () } } = {}
	local working = false
	local function enqueue(key: string, run: () -> (), first: boolean?)
		for i = #queue, 1, -1 do
			if queue[i].key == key then
				table.remove(queue, i)
			end
		end
		local job = { key = key, run = run }
		if first then
			table.insert(queue, 1, job)
		else
			table.insert(queue, job)
		end
		if working then
			return
		end
		working = true
		ui.task(function()
			while #queue > 0 do
				local j = table.remove(queue, 1)
				slice_start = os.clock()
				local ok, why = pcall(j.run)
				if not ok then
					print(`cad: {j.key} failed: {why}`)
				end
			end
			working = false
		end)
	end

	-- A design built apart from any chat's: its mesh, bounds and parts.
	local function compute(design: any, values: any): any
		local r = geom.build(design, values)
		return { mesh = mesh_of(r.polys), bounds = csg.bounds(r.polys), parts = r.parts }
	end

	-- Section: the solid kept on one side of a plane across an axis, its cut
	-- faces as caps (part -1). `at` runs 0 to 1 across the bounds.
	local AXIS = { x = 1, y = 2, z = 3 }
	function M.section_plane(b: { number }, axis: string, at: number): number
		local ai = AXIS[axis] or 3
		at = math.clamp(at, 0.002, 0.998)
		return b[ai] + (b[ai + 3] - b[ai]) * at
	end
	function M.section(sid: string, opts: any?)
		local doc = M.get(sid)
		if not opts then
			if doc.section then
				doc.section = nil
				bump()
			end
			return
		end
		local key = `{doc.built}:{opts.axis}:{opts.at}:{opts.flip}`
		local sec = doc.section or {}
		doc.section = sec
		if sec.key == key or sec.want == key then
			return
		end
		local polys, b = doc.polys, doc.bounds
		if not polys or not b then
			return
		end
		sec.want = key
		enqueue(`section:{sid}`, function()
			local m = math.max(b[4] - b[1], b[5] - b[2], b[6] - b[3]) * 0.05 + 1
			local lo = { b[1] - m, b[2] - m, b[3] - m }
			local hi = { b[4] + m, b[5] + m, b[6] + m }
			local ai = AXIS[opts.axis] or 3
			local pos = M.section_plane(b, opts.axis, opts.at)
			if opts.flip then
				lo[ai] = pos
			else
				hi[ai] = pos
			end
			local cutter = geom.cuboid(lo[1], lo[2], lo[3], hi[1], hi[2], hi[3], -1, "cap")
			local mesh = mesh_of(csg.intersect(polys, cutter))
			if doc.section == sec and sec.want == key then
				sec.key, sec.mesh, sec.pos = key, mesh, pos
				tell()
			end
		end, true)
	end

	-- Several meshes as one, each a piece with its own view tree (`pieces`:
	-- its root node, centre and the way it moves out) and each corner's piece.
	local function combine(list: { any }): any
		local out = {
			vx = {}, vy = {}, vz = {}, vp = {}, tri = {}, tn = {}, tc = {}, tp = {}, colors = {},
			np = {}, nf = {}, nb = {}, nt0 = {}, nt1 = {}, ns0 = {}, ns1 = {}, sa = {}, sb = {}, pieces = {},
		}
		for pi, item in list do
			local m = item.mesh
			local voff, toff, noff, soff, coff = #out.vx, #out.tc, #out.nf, #out.sa, #out.colors
			for i = 1, #m.vx do
				table.insert(out.vx, m.vx[i])
				table.insert(out.vy, m.vy[i])
				table.insert(out.vz, m.vz[i])
				table.insert(out.vp, pi)
			end
			for _, v in m.tri do
				table.insert(out.tri, v + voff)
			end
			for _, v in m.tn do
				table.insert(out.tn, v)
			end
			for _, ci in m.tc do
				table.insert(out.tc, if ci > 0 then ci + coff else 0)
			end
			for _, v in m.tp do
				table.insert(out.tp, v)
			end
			for _, c in m.colors do
				table.insert(out.colors, c)
			end
			for _, v in m.np do
				table.insert(out.np, v)
			end
			for i = 1, #m.nf do
				table.insert(out.nf, if m.nf[i] > 0 then m.nf[i] + noff else 0)
				table.insert(out.nb, if m.nb[i] > 0 then m.nb[i] + noff else 0)
				table.insert(out.nt0, m.nt0[i] + toff)
				table.insert(out.nt1, m.nt1[i] + toff)
				table.insert(out.ns0, m.ns0[i] + soff)
				table.insert(out.ns1, m.ns1[i] + soff)
			end
			for i = 1, #m.sa do
				table.insert(out.sa, m.sa[i] + voff)
				table.insert(out.sb, m.sb[i] + voff)
			end
			table.insert(out.pieces, {
				root = noff + 1,
				center = item.center,
				dir = item.dir,
				name = item.name,
				path = item.path,
			})
			csg.pause()
		end
		out.triangles = #out.tc
		out.nodes = #out.nf
		return out
	end

	-- Exploded view: each adding feature a piece of its own (with its holes),
	-- moving out from the middle along the way from the design's centre to
	-- its own.
	function M.explode(sid: string)
		local doc = M.get(sid)
		local ex = doc.exploded
		if ex and (ex.key == doc.built or ex.want == doc.built) then
			return
		end
		if not doc.design or not doc.bounds then
			return
		end
		ex = { want = doc.built, key = ex and ex.key, mesh = ex and ex.mesh }
		doc.exploded = ex
		local design, values, built, b = doc.design, doc.values, doc.built, doc.bounds :: { number }
		enqueue(`explode:{sid}`, function()
			local pieces = geom.pieces(design, values)
			local cx, cy, cz = (b[1] + b[4]) / 2, (b[2] + b[5]) / 2, (b[3] + b[6]) / 2
			local R = math.max(1, math.sqrt((b[4] - b[1]) ^ 2 + (b[5] - b[2]) ^ 2 + (b[6] - b[3]) ^ 2) / 2)
			local list = {}
			for i, pc in pieces do
				local pb = csg.bounds(pc.polys) :: { number }
				local px, py, pz = (pb[1] + pb[4]) / 2, (pb[2] + pb[5]) / 2, (pb[3] + pb[6]) / 2
				local dx, dy, dz = px - cx, py - cy, pz - cz
				local l = math.sqrt(dx * dx + dy * dy + dz * dz)
				if l < R * 0.04 then
					-- (A piece at the middle rises, or sinks, by turns.)
					dx, dy, dz = 0, 0, if i % 2 == 0 then -1 else 1
				else
					dx, dy, dz = dx / l, dy / l, dz / l
				end
				table.insert(list, { mesh = mesh_of(pc.polys), center = { px, py, pz }, dir = { dx * R * 0.9, dy * R * 0.9, dz * R * 0.9 }, name = pc.name, path = pc.path })
			end
			-- (Nothing sinks through the plate: all rise by what the lowest
			-- would sink, so it stays and the rest lift away from it.)
			local lowest = 0
			for _, item in list do
				lowest = math.min(lowest, item.dir[3])
			end
			for _, item in list do
				item.dir[3] -= lowest
			end
			local mesh = combine(list)
			if doc.exploded == ex and ex.want == built then
				ex.key, ex.mesh = built, mesh
				tell()
			end
		end)
	end
	function M.unexplode(sid: string)
		local doc = M.get(sid)
		if doc.exploded then
			doc.exploded = nil
			bump()
		end
	end

	-- Variants: takes an agent proposed, each built here to compare; one is
	-- adopted as the design (an undoable change, in the history).
	local variant_round = 0
	function M.propose(sid: string, list: { any })
		local doc = M.get(sid)
		variant_round += 1
		local round = variant_round
		doc.variants = {}
		for i, v in list do
			doc.variants[i] = {
				label = if type(v.label) == "string" and v.label ~= "" then v.label else `Variant {i}`,
				note = v.note,
				design = v.design,
				values = v.values or {},
				status = "building",
				round = round,
			}
		end
		bump()
		for i, v in doc.variants do
			enqueue(`variant:{sid}:{round}:{i}`, function()
				local ok, r = pcall(compute, v.design, v.values)
				if ok then
					v.mesh, v.bounds, v.parts, v.status = r.mesh, r.bounds, r.parts, "ready"
				else
					v.status, v.error = "error", tostring(r)
				end
				tell()
			end)
		end
	end
	function M.clear_variants(sid: string)
		local doc = M.get(sid)
		doc.variants = {}
		bump()
	end
	function M.use_variant(sid: string, i: number)
		local doc = M.get(sid)
		local v = doc.variants[i]
		if not v then
			return
		end
		doc.want_fit = true
		M.set(sid, clone(v.design), clone(v.values) or {}, nil, `Variant: {v.label}`, "you")
		v.adopted = true
		for j, other in doc.variants do
			if j ~= i then
				other.adopted = false
			end
		end
	end
	-- Waits (in a task) for every variant's build.
	function M.settle_variants(sid: string, timeout: number?): boolean
		local doc = M.get(sid)
		local limit = os.clock() + (timeout or 20)
		while true do
			local busy = false
			for _, v in doc.variants do
				if v.status == "building" then
					busy = true
				end
			end
			if not busy then
				return true
			end
			if os.clock() > limit then
				return false
			end
			ui.sleep(50):await()
		end
	end

	-- Previews of past versions (the history's): built as asked, the few
	-- most recently used kept.
	local previews: { [string]: any } = {}
	local preview_count = 0
	function M.preview(snap: string): any
		local e = previews[snap]
		if e then
			e.used = os.clock()
			return e
		end
		e = { status = "building", used = os.clock() }
		previews[snap] = e
		preview_count += 1
		-- (Keep five: the least lately used goes, unless it's still building.)
		local n = 0
		for _ in previews do
			n += 1
		end
		while n > 5 do
			local oldest, at = nil, math.huge
			for k, p in previews do
				if p.status ~= "building" and p.used < at then
					oldest, at = k, p.used
				end
			end
			if not oldest then
				break
			end
			previews[oldest] = nil
			n -= 1
		end
		local v = decode(snap) or {}
		enqueue(`preview:{preview_count}`, function()
			if previews[snap] ~= e then
				return
			end
			local ok, r = pcall(compute, v.design, v.values)
			if ok then
				e.mesh, e.bounds, e.status = r.mesh, r.bounds, "ready"
			else
				e.status, e.error = "error", tostring(r)
			end
			tell()
		end, true)
		return e
	end

	-- Puts a past version back, as a new change.
	function M.restore_version(sid: string, i: number)
		local doc = M.get(sid)
		local h = doc.history[i]
		if not h then
			return
		end
		local v = decode(h.snap) or {}
		if not v.design then
			return
		end
		M.set(sid, v.design, v.values or {}, nil, `Restored: {h.label}`, "you")
	end

	M.encode, M.decode = encode, decode
	return M
end
