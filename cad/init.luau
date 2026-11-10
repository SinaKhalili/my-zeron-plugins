local zeron = require("./zeron")("cad")

-- CAD: a parametric modeller beside the chat. The agent writes the design
-- (plain JSON, through this plugin's tools); the person shapes it in the
-- CAD tab with the mouse (orbit, pick, sketch, measure), sliders for its
-- parameters, and the selected part's numbers. Each chat has its own
-- design, kept in the plugin's database.
--
--   expr.luau     numbers as expressions of the parameters
--   csg.luau      booleans on polygon solids (BSP trees), in slices
--   geom.luau     a design made solid: primitives, transforms, patterns
--   designs.luau  each chat's design: history, builds, the mesh, STL
--   render.luau   the viewport, drawn in software on a canvas
--   view.luau     the tab
--   examples.luau designs to start from

local docs = require("./designs")(zeron)
local geom = require("./geom")
local Tab = require("./view")(zeron, docs)
local IconButton = require("@ds/icon_button").IconButton

local function open(panel: any, sid: string)
	panel.open_tab {
		kind = "cad",
		title = "CAD",
		icon = "widget",
		data = { key = `cad:{sid}`, session = sid },
	}
end

zeron.tab("cad", function(tab: any): Node
	return Tab { tab = tab }
end)

-- In each chat's header: open its CAD tab. It opens by itself, too, when
-- an agent sets the chat's design.
zeron.place {
	at = "#page-title",
	after = function(): Node
		local sid = zeron.need("session").id
		local panel = zeron.context("panel")
		ui.effect(function()
			docs.tick:get()
			local d = docs.get(sid)
			if d.open_asked and panel then
				d.open_asked = false
				open(panel, sid)
			end
		end)
		return IconButton {
			icon = "widget",
			label = "CAD",
			size = "sm",
			tone = "quiet",
			on_click = function()
				if panel then
					open(panel, sid)
				end
			end,
		}
	end,
}

-- Tools for agents ----------------------------------------------------------

local function chat_of(call: any): string
	local sid = call and call.chat
	if type(sid) ~= "string" or sid == "" then
		error("Call this from a chat: each chat has its own design.", 0)
	end
	return sid
end

local function selection(d: any): any
	local p = docs.part(d, d.selected)
	if not p then
		return nil
	end
	local out: any = { path = p.path, name = p.name, type = p.type, node = geom.at(d.design, p.path) }
	-- (The face the person clicked on it: where, and which way it faces.)
	local pk = d.pick
	if pk and pk.path == p.path then
		out.face = { point = pk.point, normal = pk.normal, facing = docs.facing(pk.normal) }
	end
	return out
end

-- A short label for the history from what the agent said it did.
local function said(args: any, default: string): string
	local s = if type(args.summary) == "string" and args.summary ~= "" then args.summary else default
	return "AI: " .. s
end

local function answer(sid: string, extra: { [string]: any }?): any
	local settled = docs.settle(sid)
	local d = docs.get(sid)
	local out = docs.summary(d)
	out.selection = selection(d)
	if not settled then
		out.status = "building"
		out.hint = "Still building (a heavy boolean): call get_design in a few seconds for the result."
	elseif out.status == "error" then
		out.hint = "The design didn't build. Fix what `error` names (its path, e.g. body.2.size[1]) and call set_design again."
	elseif out.status == "ready" then
		out.hint = "The person sees it in the chat's CAD tab: they can orbit it, drag the parameters' sliders, select parts and edit their numbers."
	end
	for k, v in extra or {} do
		out[k] = v
	end
	return out
end

zeron.tool {
	name = "get_design",
	run = function(_args: any, call: any): any
		local sid = chat_of(call)
		docs.settle(sid)
		local d = docs.get(sid)
		if d.design == nil then
			return { hint = "This chat has no design yet: make one with set_design." }
		end
		return answer(sid, { design = d.design, values = d.values })
	end,
}

zeron.tool {
	name = "set_design",
	run = function(args: any, call: any): any
		local sid = chat_of(call)
		local design = args.design
		if type(design) == "string" then
			local ok, v = pcall(ui.json.decode, design)
			design = if ok then v else nil
		end
		if type(design) ~= "table" or type(design.body) ~= "table" then
			error("`design` must be an object with a `body` list of nodes.", 0)
		end
		docs.settle(sid)
		local d = docs.get(sid)
		d.want_fit = d.design == nil or args.fit == true
		-- (Plain tables of its own: what a call gives may be read-only.)
		docs.set(sid, docs.clone(design), if type(args.values) == "table" then docs.clone(args.values) else nil, nil, said(args, design.name or "new design"), "ai")
		docs.ask_open(sid)
		return answer(sid)
	end,
}

zeron.tool {
	name = "set_params",
	run = function(args: any, call: any): any
		local sid = chat_of(call)
		docs.settle(sid)
		local d = docs.get(sid)
		if d.design == nil then
			error("This chat has no design yet: make one with set_design.", 0)
		end
		if type(args.values) ~= "table" then
			error("`values` must be an object of parameter id to value.", 0)
		end
		local known = {}
		for _, p in d.design.params or {} do
			if type(p) == "table" and p.id then
				known[p.id] = true
			end
		end
		for k in args.values do
			if not known[k] then
				error(`No parameter "{k}" in this design.`, 0)
			end
		end
		docs.set_values(sid, docs.clone(args.values), "ai")
		return answer(sid)
	end,
}

zeron.tool {
	name = "edit_part",
	run = function(args: any, call: any): any
		local sid = chat_of(call)
		docs.settle(sid)
		local d = docs.get(sid)
		if d.design == nil then
			error("This chat has no design yet: make one with set_design.", 0)
		end
		local path = args.path
		if type(path) ~= "string" or geom.at(d.design, path) == nil then
			error(`No node at "{tostring(path)}". Paths look like body.2 or body.3.children.1 (from get_design's parts).`, 0)
		end
		local set = if type(args.set) == "table" then docs.clone(args.set) else nil
		docs.edit(sid, function(design: any)
			local node, list, i = geom.at(design, path)
			if args.remove == true then
				if list and i then
					table.remove(list, i)
				end
				return
			end
			for k, v in set or {} do
				node[k] = v
			end
			if type(args.unset) == "table" then
				for _, k in args.unset do
					node[k] = nil
				end
			end
		end, said(args, if args.remove == true then `removed {path}` else `edited {(geom.at(d.design, path) or {}).name or path}`), "ai")
		if args.remove == true and d.selected == path then
			docs.select(sid, nil)
		end
		docs.ask_open(sid)
		return answer(sid)
	end,
}

zeron.tool {
	name = "propose_variants",
	run = function(args: any, call: any): any
		local sid = chat_of(call)
		if type(args.variants) ~= "table" or #args.variants == 0 then
			error("`variants` must be a list of { label, design, values?, note? }.", 0)
		end
		if #args.variants > 6 then
			error("Up to 6 variants at a time.", 0)
		end
		local list = {}
		for i, v in args.variants do
			if type(v) ~= "table" or type(v.design) ~= "table" or type(v.design.body) ~= "table" then
				error(`variants[{i}] needs a design with a body.`, 0)
			end
			table.insert(list, {
				label = v.label,
				note = v.note,
				design = docs.clone(v.design),
				values = if type(v.values) == "table" then docs.clone(v.values) else nil,
			})
		end
		docs.settle(sid)
		docs.propose(sid, list)
		docs.ask_open(sid)
		local settled = docs.settle_variants(sid)
		local out = {}
		for i, v in docs.get(sid).variants do
			local b = v.bounds
			table.insert(out, {
				index = i,
				label = v.label,
				status = v.status,
				error = v.error,
				size = if b then { b[4] - b[1], b[5] - b[2], b[6] - b[3] } else nil,
			})
		end
		return {
			variants = out,
			settled = settled,
			hint = "They're side by side in the CAD tab's Variants: the person points at one to see it and picks one with Use (it becomes the design). Fix any that errored and propose again if needed.",
		}
	end,
}
