-- Cosmos' rocket, in three dimensions: one of fleet.luau's models, drawn by
-- `ui.scene3d`, with its lights, its exhaust and how it moves.
--
-- Y is up and the ground is y = 0. Nothing here moves on its own: every
-- moving number is bound to a state the caller holds (`ui.tween`), so a
-- standing rocket draws no frames.

local fleet = require("./fleet")
local solids = require("./solids")

local M = {}

M.KINDS = fleet.KINDS

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

-- What a model's parts are made of. (Black is a little lifted on a dark
-- window: or a roll pattern is holes in the rocket.)
local function materials(light: boolean): { [string]: any }
	local steel = { color = "#7d8494", metallic = 0.7, roughness = 0.4 }
	local dark = { color = "#17191f", metallic = 0.3, roughness = 0.6 }
	return {
		white = { color = "#f4f5f8", metallic = 0, roughness = 0.42 },
		black = { color = if light then "#23262e" else "#525868", metallic = 0, roughness = 0.5 },
		silver = { color = "#c9ced9", metallic = 0.25, roughness = 0.3 },
		grey = { color = "#a9afbb", metallic = 0, roughness = 0.5 },
		steel = steel,
		dark = dark,
		tower = if light then dark else steel,
		-- Polished steel, a tank's foam and its ribbed middle, a Soyuz's
		-- paint and its nozzles.
		inox = { color = "#d5d9e2", metallic = 0.2, roughness = 0.26 },
		foam = { color = "#c9682c", metallic = 0, roughness = 0.85 },
		rust = { color = "#a9541f", metallic = 0, roughness = 0.9 },
		sage = { color = "#aeb7a6", metallic = 0, roughness = 0.55 },
		copper = { color = "#b0603a", metallic = 0.6, roughness = 0.4 },
	}
end

-- An exhaust's colours at its tail and at its top, its strength, and its
-- core's: by what burns. (On a light window each is deepened, or it is
-- white on white.)
local FLAMES: { [string]: any } = {
	kerolox = { tail = { 1, 0.64, 0.3 }, top = { 1, 0.9, 0.62 }, alpha = 0.85, fade = 1.3, core = { 1, 0.95, 0.8 }, deep = { 1, 0.6, 0.29 } },
	solid = { tail = { 1, 0.74, 0.44 }, top = { 1, 0.95, 0.78 }, alpha = 0.95, fade = 1.1, core = { 1, 1, 0.92 }, deep = { 1, 0.64, 0.3 } },
	hydrolox = { tail = { 0.55, 0.7, 1 }, top = { 0.82, 0.9, 1 }, alpha = 0.5, fade = 1.4, core = { 0.95, 0.98, 1 }, deep = { 0.4, 0.55, 1 } },
	methalox = { tail = { 0.66, 0.5, 1 }, top = { 0.74, 0.8, 1 }, alpha = 0.75, fade = 1.4, core = { 0.96, 0.95, 1 }, deep = { 0.5, 0.42, 1 } },
}

-- A model's exhausts as two meshes, tail to top: the flames and, inside
-- them, their white-hot cores, each thinning to nothing (the colours carry
-- their own alpha). Built once for a kind and a window.
local flames: { [string]: any } = {}
local function exhaust(kind: string, model: fleet.Model, light: boolean): any
	local key = `{kind}:{light}`
	if flames[key] then
		return flames[key]
	end
	local outer, inner = {}, {}
	for _, p in model.plumes do
		local f = FLAMES[p.kind]
		local deep = if light then f.deep else { 1, 1, 1 }
		local plume, core = {}, {}
		for i = 0, 12 do
			local t = i / 12
			local r = p.r * t ^ 0.5 * (1 - 0.16 * math.sin(math.pi * t) ^ 2)
			table.insert(plume, {
				r,
				p.y - 0.005 - p.len * (1 - t),
				(f.tail[1] + (f.top[1] - f.tail[1]) * t) * deep[1],
				(f.tail[2] + (f.top[2] - f.tail[2]) * t) * deep[2],
				(f.tail[3] + (f.top[3] - f.tail[3]) * t) * deep[3],
				f.alpha * t ^ f.fade,
			})
			table.insert(core, { 0.55 * p.r * t ^ 0.7, p.y - 0.004 - 0.5 * p.len * (1 - t), f.core[1], f.core[2], f.core[3], t ^ 1.1 })
		end
		table.insert(outer, { solids.lathe(plume, 20), 0, p.x, p.z })
		table.insert(inner, { solids.lathe(core, 14), 0, p.x, p.z })
	end
	flames[key] = { plume = solids.merge(outer), core = solids.merge(inner) }
	return flames[key]
end

export type Ship = {
	-- Which rocket: one of `KINDS`.
	kind: string,
	w: number,
	h: number,
	-- How many units the box shows, top to bottom, and how many of them lie
	-- under the ground.
	view: number,
	ground: number,
	-- 0 standing, 1 aloft.
	fly: any,
	-- 0 cold, 1 burning.
	burn: any,
	-- 0.5 level; 0 and 1 the ends of its sway while it hovers.
	bob: any,
	turn: any,
	-- 0 and 1: the exhaust's two lengths.
	flick: any,
	-- How far it climbs, in units, and how long that takes.
	climb: number,
	climb_ms: number,
	light: boolean,
	-- Turned this far as it stands instead of its model's own heading.
	heading: number?,
}

function M.scene(o: Ship): Node
	local model = fleet.model(o.kind)
	local made = materials(o.light)
	local fire = exhaust(o.kind, model, o.light)
	local heading = o.heading or model.heading
	local rocket: { [any]: any } = {
		rotation = {
			ui.tween(o.bob, { from = -1.5, to = 1.5, duration = 1900, ease = "inOutSine" }),
			ui.tween(o.turn, { from = heading - 22, to = heading + 22, duration = 2600, ease = "inOutSine" }),
			ui.tween(o.turn, { from = 1.7, to = -1.7, duration = 2600, ease = "inOutSine" }),
		},
		position = { 0, ui.tween(o.bob, { from = -0.08, to = 0.08, duration = 1900, ease = "inOutSine" }), 0 },
	}
	for _, part in model.parts do
		table.insert(rocket, ui.mesh { geometry = part.geometry, material = made[part.material] })
	end
	if model.moving then
		for _, object in model.moving(o, made) do
			table.insert(rocket, object)
		end
	end
	table.insert(rocket, ui.mesh {
		geometry = fire.core,
		material = { color = "#ffffff", unlit = true, double_sided = true, opacity = ui.tween(o.burn, { from = 0, to = 1, duration = 180 }) },
	})
	table.insert(rocket, ui.mesh {
		geometry = fire.plume,
		scale = { 1, ui.tween(o.flick, { from = 0.9, to = 1.06, duration = 150, ease = "inOutSine" }), 1 },
		material = { color = "#ffffff", unlit = true, double_sided = true, opacity = ui.tween(o.burn, { from = 0, to = 1, duration = 260 }) },
	})
	local function lift(): any
		return ui.tween(o.fly, { from = 0, to = o.climb, duration = o.climb_ms, ease = "inOut(2.2)" })
	end
	-- The camera: far off and a little above.
	local pitch = math.rad(7)
	local dist = o.view / (2 * math.tan(math.rad(11)))
	local mid = o.view / 2 - o.ground
	return ui.scene3d {
		w = o.w,
		h = o.h,
		pointer_events = "none",
		label = "Rocket",
		environment = "none",
		camera = {
			fov = 22,
			position = { 0, mid + dist * math.sin(pitch), dist * math.cos(pitch) },
			target = { 0, mid, 0 },
		},
		-- One sun from the upper left (a scene's suns share a direction, so
		-- the rest are bulbs): a rim in the accent from behind, the sky's
		-- fill, and the engines' own glow while they burn.
		ui.light { kind = "directional", direction = { 0.55, -0.5, -0.62 }, intensity = if o.light then 2.7 else 3.1 },
		ui.light { kind = "point", position = { 3, 2.4, -1.9 }, range = 14, color = "$accent", intensity = if o.light then 26 else 52 },
		ui.light { kind = "hemisphere", color = "#dfe6ff", ground = "#2c3252", intensity = if o.light then 0.42 else 0.28 },
		ui.light {
			kind = "point",
			position = { 0, lift(), 0.6 },
			color = model.fire,
			range = 2.4,
			intensity = ui.tween(o.burn, { from = 0, to = 1.3, duration = 260 }),
		},
		ui.group { position = { 0, lift(), 0 }, ui.group(rocket) },
	}
end

return M
