-- Cosmos' rockets: stylized models of real ones, each built once from its
-- own triangles (solids.luau). Their stations are the real vehicles', in
-- metres from the ground they stand on; each is shortened for its width
-- (`squat`) so a slender stack still shows at a message box's size.
--
-- A model is its meshes by material (ship.luau names the materials), where
-- its exhausts hang, and what of it moves.

local solids = require("./solids")
local lathe, wedge, box, strut, merge, ring, leaning =
	solids.lathe, solids.wedge, solids.box, solids.strut, solids.merge, solids.ring, solids.leaning

local M = {}

-- The ones there are, the first the default.
M.KINDS = { "saturn", "shuttle", "falcon", "starship", "soyuz" }

export type Plume = { x: number, z: number, y: number, r: number, len: number, kind: string }
export type Model = {
	parts: { { geometry: any, material: string } },
	plumes: { Plume },
	-- The colour its engines light it by.
	fire: string,
	-- How far it is turned as it stands, in degrees.
	heading: number,
	-- What of it follows the flight's states: more objects for its group.
	moving: ((o: any, materials: { [string]: any }) -> { any })?,
}

local QUARTER = math.pi / 2

-- A model's workbench: metres in, units out. `tall` metres stand `height`
-- units, a metre across `1 / squat` of a metre up.
local function kit(tall: number, squat: number, height: number)
	local ky = height / tall
	local kr = ky / squat
	local bins: { [string]: { { any } } } = {}
	local order: { string } = {}
	local k = { ky = ky, kr = kr, plumes = {} :: { Plume } }
	-- A geometry in a material: turned to an angle, then moved (metres).
	function k.add(material: string, g: any, turn: number?, x: number?, z: number?)
		local key = if g.normals then material else material .. ":flat"
		if not bins[key] then
			bins[key] = {}
			table.insert(order, key)
		end
		table.insert(bins[key], { g, turn or 0, (x or 0) * kr, (z or 0) * kr })
	end
	-- A profile of { r, y } in metres, `proud` units off it.
	function k.prof(points: { { number } }, proud: number?): { solids.Ring }
		local out = {}
		for _, p in points do
			table.insert(out, { p[1] * kr + (proud or 0), p[2] * ky })
		end
		return out
	end
	-- An outline of { x, y } in metres.
	function k.flat(points: { { number } }): { { number } }
		local out = {}
		for _, p in points do
			table.insert(out, { p[1] * kr, p[2] * ky })
		end
		return out
	end
	-- An exhaust under (x, z), from the height `y`: `r` metres wide at its
	-- top and `len` units long.
	function k.plume(x: number, z: number, y: number, r: number, len: number, kind: string)
		table.insert(k.plumes, { x = x * kr, z = z * kr, y = y * ky, r = r * kr, len = len, kind = kind })
	end
	-- Engine bells of one profile ({ r, y } from its rim up), at spots of
	-- { x, z } metres.
	function k.bells(material: string, bell: { { number } }, seg: number, spots: { { number } })
		local g = lathe(k.prof(bell), seg)
		for _, s in spots do
			k.add(material, g, 0, s[1], s[2])
		end
	end
	function k.parts(): { { geometry: any, material: string } }
		local out = {}
		for _, key in order do
			table.insert(out, { geometry = merge(bins[key]), material = (string.gsub(key, ":flat$", "")) })
		end
		return out
	end
	return k
end

-- A nose from the radius `r` at `y0` to its tip at `y1`: fuller as `p`
-- grows, blunter as `q` shrinks.
local function nose(r: number, y0: number, y1: number, steps: number, p: number, q: number): { { number } }
	local out = {}
	for i = 0, steps do
		local t = i / steps
		table.insert(out, { r * (1 - t ^ p) ^ q, y0 + (y1 - y0) * t })
	end
	return out
end

-- A radius between stations of { r, y }: straight from one to the next.
local function between(stack: { { number } }): (y: number) -> number
	return function(y: number): number
		for i = 2, #stack do
			local a, b = stack[i - 1], stack[i]
			if y <= b[2] then
				return a[1] + (b[1] - a[1]) * math.clamp((y - a[2]) / (b[2] - a[2]), 0, 1)
			end
		end
		return stack[#stack][1]
	end
end

local PROUD = 0.003

-- The Saturn V that flew Apollo: the first stage with its four fins and
-- five engines, the second, the taper to the third, the adapter, the
-- service and command modules and the escape tower, in the flights' black
-- and white roll pattern.
local function saturn(): Model
	local k = kit(110.6, 0.82, 4.2)
	local seg, base = 32, 3.6
	local stack = { { 5.03, base }, { 5.03, 66.8 }, { 3.3, 72.6 }, { 3.3, 85.3 }, { 1.96, 93.8 }, { 1.96, 98 }, { 0.3, 101.5 } }
	local girth = between(stack)
	local function skin(y0: number, y1: number): { solids.Ring }
		return k.prof({ { girth(y0), y0 }, { girth(y1), y1 } }, PROUD)
	end
	for i = 2, #stack do
		k.add(if i == 6 then "silver" else "white", lathe(k.prof({ stack[i - 1], stack[i] }), seg))
	end
	-- The escape tower's rocket, over the command module.
	k.add("white", lathe(k.prof({ { 0.56, 104.2 }, { 0.36, 105 }, { 0.36, 109.2 }, { 0.05, 110.6 } }), 12))
	local fairing = lathe(k.prof({ { 2.25, base }, { 0.02, 11.8 } }), 14)
	local fin = wedge(k.flat({ { 5, 9.8 }, { 8.9, 5.4 }, { 8.9, 3.2 }, { 5, 3.2 } }), 0.24 * k.kr, 0.1 * k.kr)
	local bell = { { 1.82, 0 }, { 1.5, 1.3 }, { 1.02, 2.7 }, { 0.62, 3.8 } }
	k.bells("steel", bell, 14, { { 0, 0 } })
	local eighth = QUARTER / 4
	for _, at in ring(4, 1) do
		local a = at[3]
		k.add("white", fairing, 0, 4.2 * at[1], 4.2 * at[2])
		k.add("white", fin, a)
		k.bells("steel", bell, 14, { { 3.7 * at[1], 3.7 * at[2] } })
		-- The roll pattern: a black stripe up the first stage over each
		-- fin, and blocks at the top of it and at either end of the third,
		-- each an eighth of the way round.
		k.add("black", lathe(skin(base, 21.5), 4, a - eighth, a + eighth))
		k.add("black", lathe(skin(38.2, 42), 4, a + eighth, a + 3 * eighth))
		k.add("black", lathe(skin(72.6, 75.4), 4, a - eighth, a + eighth))
		k.add("black", lathe(skin(82.4, 85.3), 4, a + eighth, a + 3 * eighth))
		-- A leg of the tower.
		local b = a + QUARTER / 2
		k.add(
			"tower",
			strut(
				{ 0.62 * k.kr * math.cos(b), 101.3 * k.ky, 0.62 * k.kr * math.sin(b) },
				{ 0.4 * k.kr * math.cos(b), 104.4 * k.ky, 0.4 * k.kr * math.sin(b) },
				0.1 * k.kr
			)
		)
	end
	-- The band about the second stage's foot, and the joints of the stack.
	k.add("black", lathe(skin(45.9, 47.5), seg))
	for _, y in { 42, 66.8, 93.8, 98 } do
		k.add("black", lathe(skin(y - 0.2, y + 0.2), seg))
	end
	k.plume(0, 0, 0, 5.4, 0.98, "kerolox")
	return { parts = k.parts(), plumes = k.plumes, fire = "#ffc88a", heading = 24 }
end

-- The Space Shuttle: the orange tank, a white booster to either side and
-- the orbiter on its back, black beneath and at its nose.
local function shuttle(): Model
	local k = kit(56.1, 0.8, 3.5)
	-- The tank: a dome, a barrel and a long nose, its ribbed middle darker.
	local tank: { { number } } = {}
	for i = 0, 5 do
		local t = i / 5 * QUARTER
		table.insert(tank, { 4.2 * math.sin(t), 8.4 - 5 * math.cos(t) })
	end
	table.insert(tank, { 4.2, 24 })
	for _, p in nose(4.2, 40, 55.5, 8, 1.9, 0.8) do
		table.insert(tank, p)
	end
	table.insert(tank, { 0, 56.1 })
	k.add("foam", lathe(k.prof(tank), 32))
	k.add("rust", lathe(k.prof({ { 4.2, 30.5 }, { 4.2, 37.2 } }, PROUD), 32))
	-- The boosters: a flared skirt, the casing with its joints, a cone.
	for _, side in { -1, 1 } do
		local x = side * 6.3
		k.add("white", lathe(k.prof({ { 2.7, 0 }, { 1.85, 3 } }), 20), 0, x, 0)
		k.add("white", lathe(k.prof({ { 1.85, 3 }, { 1.85, 41.3 } }), 20), 0, x, 0)
		k.add("white", lathe(k.prof({ { 1.85, 41.3 }, { 0.3, 45 }, { 0, 45.5 } }), 20), 0, x, 0)
		for _, y in { 3, 12.6, 22.2, 31.8, 41.3 } do
			k.add("black", lathe(k.prof({ { 1.85, y - 0.22 }, { 1.85, y + 0.22 } }, PROUD), 20), 0, x, 0)
		end
		k.plume(x, 0, 0, 2.3, 1.02, "solid")
	end
	-- The orbiter, its back to the viewer: white above, black beneath.
	local oz = 7.2
	local body = { { 2.6, 6.8 }, { 2.6, 31.5 } }
	local cone = nose(2.6, 31.5, 42.2, 8, 2, 0.62)
	for i = 2, #cone do
		table.insert(body, cone[i])
	end
	k.add("white", lathe(k.prof(body), 12, 0, math.pi), 0, 0, oz)
	k.add("black", lathe(k.prof(body), 12, math.pi, 2 * math.pi), 0, 0, oz)
	-- (Its nose cap and its windows.)
	local cap = {}
	for i = 6, #cone do
		table.insert(cap, cone[i])
	end
	k.add("black", lathe(k.prof(cap, PROUD), 12, 0, math.pi), 0, 0, oz)
	local shade = between(cone)
	k.add("black", lathe(k.prof({ { shade(36.2), 36.2 }, { shade(37.9), 37.9 } }, PROUD * 2), 6, QUARTER - 0.8, QUARTER + 0.8), 0, 0, oz)
	-- Wings (a black one under each, a little larger: its tiles show at the
	-- edge), their strakes and the tail.
	local wz = (oz - 1.6) * k.kr
	for _, side in { -1, 1 } do
		local function half(points: { { number } }): { { number } }
			local out = {}
			for _, p in points do
				table.insert(out, { side * p[1], p[2] })
			end
			return k.flat(out)
		end
		local thick, thin = 0.34 * k.kr, 0.12 * k.kr
		local a, b = if side > 0 then thick else thin, if side > 0 then thin else thick
		k.add("white", wedge(half({ { 2.2, 25.5 }, { 11.9, 11.2 }, { 11.9, 8.4 }, { 2.2, 7 } }), a, b, wz))
		k.add("white", wedge(half({ { 2.2, 31.5 }, { 5, 21.4 }, { 2.2, 21.4 } }), a, b, wz))
		k.add("black", wedge(half({ { 2.2, 27 }, { 12.6, 11.5 }, { 12.6, 8 }, { 2.2, 6.6 } }), a, b, wz - 0.3 * k.kr))
		k.add("black", wedge(half({ { 2.2, 33 }, { 5.6, 21 }, { 2.2, 21 } }), a, b, wz - 0.3 * k.kr))
	end
	k.add("white", wedge(k.flat({ { 2.4, 14 }, { 8.8, 9 }, { 8.8, 6.5 }, { 2.4, 7 } }), 0.3 * k.kr, 0.12 * k.kr), QUARTER, 0, oz)
	-- Its three engines, and the boosters' nozzles.
	k.bells("steel", { { 1.15, 4 }, { 0.9, 5.2 }, { 0.5, 6.8 } }, 10, { { 0, oz + 1.2 }, { -1.35, oz - 0.7 }, { 1.35, oz - 0.7 } })
	k.plume(0, oz, 4, 1.9, 0.52, "hydrolox")
	return { parts = k.parts(), plumes = k.plumes, fire = "#ffd9a0", heading = -26 }
end

-- A Falcon 9: a white first stage on a black base, the black interstage
-- with its grid fins folded, the second stage and the fairing. Its four
-- legs fold up as it leaves and open as it comes back.
local function falcon(): Model
	local k = kit(70, 0.5, 4)
	local seg = 28
	k.add("black", lathe(k.prof({ { 1.83, 1.2 }, { 1.83, 2.8 } }), seg))
	k.add("white", lathe(k.prof({ { 1.83, 2.8 }, { 1.83, 41.2 } }), seg))
	k.add("black", lathe(k.prof({ { 1.83, 41.2 }, { 1.83, 47.6 } }), seg))
	k.add("white", lathe(k.prof({ { 1.83, 47.6 }, { 1.83, 57 } }), seg))
	k.add("white", lathe(k.prof({ { 1.83, 57 }, { 2.35, 58.8 } }), seg))
	local top = { { 2.35, 58.8 } }
	for _, p in nose(2.35, 61.6, 70, 9, 1.7, 0.8) do
		table.insert(top, p)
	end
	k.add("white", lathe(k.prof(top), seg))
	-- The raceway up one side, and a grid fin folded flat between each pair
	-- of legs.
	k.add("grey", box(1.83 * k.kr, 3.2 * k.ky, -0.14 * k.kr, 1.83 * k.kr + 0.012, 56.4 * k.ky, 0.14 * k.kr), 0.5)
	for _, at in ring(4, 1, QUARTER / 2) do
		k.add("silver", box(1.83 * k.kr, 43.6 * k.ky, -0.62 * k.kr, 1.83 * k.kr + 0.016, 46.6 * k.ky, 0.62 * k.kr), at[3])
	end
	-- Nine engines: one in a ring of eight.
	local spots = { { 0, 0 } }
	for _, at in ring(8, 1.27) do
		table.insert(spots, { at[1], at[2] })
	end
	k.bells("steel", { { 0.46, 0.4 }, { 0.34, 1.1 }, { 0.2, 2 } }, 8, spots)
	k.plume(0, 0, 0.4, 2, 0.95, "kerolox")
	-- A leg, along +X from its hinge: wide there, narrow at its foot.
	local hinge, foot = { 1.83 * k.kr, 2.8 * k.ky }, 0.42
	local reach = math.sqrt(foot * foot + hinge[2] * hinge[2])
	local leg = wedge({ { 0, 0.03 }, { reach, 0.018 }, { reach, 0 }, { 0, 0 } }, 0.09, 0.028)
	local open = -math.deg(math.atan2(hinge[2], foot))
	return {
		parts = k.parts(),
		plumes = k.plumes,
		fire = "#ffc88a",
		heading = 32,
		moving = function(o: any, materials: { [string]: any }): { any }
			local legs = {}
			for _, at in ring(4, hinge[1]) do
				table.insert(legs, ui.group {
					position = { at[1], hinge[2], at[2] },
					rotation = { 0, -math.deg(at[3]), 0 },
					ui.mesh {
						geometry = leg,
						material = materials.black,
						rotation = { 0, 0, ui.tween(o.fly, { from = open, to = 87, duration = math.max(o.climb_ms * 0.8, 1), ease = "inOut(2)" }) },
					},
				})
			end
			return legs
		end,
	}
end

-- Starship on its booster: steel, the ship's far side black with tiles,
-- its four flaps, the booster's grid fins and strakes.
local function starship(): Model
	local k = kit(121, 0.8, 4.2)
	local seg = 32
	k.add("inox", lathe(k.prof({ { 4.5, 1.6 }, { 4.5, 69 } }), seg))
	k.add("steel", lathe(k.prof({ { 4.5, 69 }, { 4.5, 71 } }), seg))
	local ship = { { 4.5, 71 } }
	for _, p in nose(4.5, 102, 121, 9, 1.9, 0.86) do
		table.insert(ship, p)
	end
	k.add("inox", lathe(k.prof(ship), seg, 0, math.pi))
	k.add("black", lathe(k.prof(ship), seg, math.pi, 2 * math.pi))
	k.add("black", lathe(k.prof({ { 4.5, 1.6 }, { 4.5, 4.4 } }, PROUD), seg))
	for _, side in { -1, 1 } do
		local function half(points: { { number } }): { { number } }
			local out = {}
			for _, p in points do
				table.insert(out, { side * p[1], p[2] })
			end
			return k.flat(out)
		end
		local a, b = if side > 0 then 0.3 * k.kr else 0.16 * k.kr, if side > 0 then 0.16 * k.kr else 0.3 * k.kr
		k.add("black", wedge(half({ { 4.3, 82 }, { 8.4, 78.6 }, { 8.4, 72.4 }, { 4.3, 71.6 } }), a, b))
		k.add("black", wedge(half({ { 4.1, 112.6 }, { 6.7, 109.6 }, { 6.7, 105.2 }, { 4.3, 104.2 } }), a, b))
	end
	for _, at in ring(4, 1, QUARTER / 2) do
		k.add("steel", box(4.4 * k.kr, 66 * k.ky, -1.5 * k.kr, 7.7 * k.kr, 66.9 * k.ky, 1.5 * k.kr), at[3])
	end
	for _, at in ring(4, 1) do
		k.add("inox", box(4.4 * k.kr, 4.4 * k.ky, -0.5 * k.kr, 5.1 * k.kr, 21 * k.ky, 0.5 * k.kr), at[3])
	end
	-- Its engines, as a ring about three.
	local spots = {}
	for _, at in ring(10, 3.6) do
		table.insert(spots, { at[1], at[2] })
	end
	for _, at in ring(3, 1.2) do
		table.insert(spots, { at[1], at[2] })
	end
	k.bells("steel", { { 0.75, 0.2 }, { 0.55, 1.1 }, { 0.3, 2 } }, 8, spots)
	k.plume(0, 0, 0.2, 4.6, 1, "methalox")
	return { parts = k.parts(), plumes = k.plumes, fire = "#b9b4ff", heading = 38 }
end

-- A Soyuz: the core and four tapering boosters leaning on it, each on four
-- nozzles, the third stage over its open truss, the white fairing and the
-- escape tower.
local function soyuz(): Model
	local k = kit(49.5, 0.75, 4)
	local seg = 24
	k.add("sage", lathe(k.prof({ { 1.03, 1 }, { 1.03, 14.5 } }), seg))
	k.add("sage", lathe(k.prof({ { 1.03, 14.5 }, { 1.475, 20.5 } }), seg))
	k.add("sage", lathe(k.prof({ { 1.475, 20.5 }, { 1.33, 27.5 } }), seg))
	k.add("dark", lathe(k.prof({ { 1.18, 27.5 }, { 1.18, 28.7 } }), seg))
	k.add("sage", lathe(k.prof({ { 1.33, 28.7 }, { 1.33, 35.4 } }), seg))
	k.add("white", lathe(k.prof({ { 1.33, 35.4 }, { 1.5, 36.4 } }), seg))
	k.add("white", lathe(k.prof({ { 1.5, 36.4 }, { 1.5, 41.6 } }), seg))
	k.add("white", lathe(k.prof({ { 1.5, 41.6 }, { 0.42, 45.4 } }), seg))
	k.add("white", lathe(k.prof({ { 0.3, 45.4 }, { 0.3, 47 }, { 0.52, 47.4 }, { 0.52, 47.9 }, { 0.3, 48.3 }, { 0.3, 49 }, { 0.04, 49.5 } }), 10))
	k.add("black", lathe(k.prof({ { 1.475, 20.5 }, { 1.46, 21.3 } }, PROUD), seg))
	k.add("black", lathe(k.prof({ { 1.33, 34.6 }, { 1.33, 35.4 } }, PROUD), seg))
	local bell = { { 0.4, 0 }, { 0.3, 0.6 }, { 0.2, 1.2 } }
	local four = ring(4, 0.52, QUARTER / 2)
	local function nozzles(x: number, z: number)
		local spots = {}
		for _, at in four do
			table.insert(spots, { x + at[1], z + at[2] })
		end
		k.bells("copper", bell, 8, spots)
	end
	nozzles(0, 0)
	k.plume(0, 0, 0, 1, 0.8, "kerolox")
	-- A booster: a short barrel under a long cone, leaning in to the core.
	local out, tip = 2.72, 1.9
	local booster = lathe(k.prof({ { 1.34, 1 }, { 1.34, 4.6 }, { 0.5, 19 }, { 0.14, 20.4 }, { 0, 20.6 } }), 16)
	booster = leaning(booster, -((out - tip) * k.kr) / (18 * k.ky), 1 * k.ky)
	local cuff = leaning(lathe(k.prof({ { 1.34, 4.2 }, { 1.31, 4.9 } }, PROUD), 16), -((out - tip) * k.kr) / (18 * k.ky), 1 * k.ky)
	for _, at in ring(4, out) do
		k.add("sage", booster, at[3], at[1], at[2])
		k.add("black", cuff, at[3], at[1], at[2])
		nozzles(at[1], at[2])
		k.plume(at[1], at[2], 0, 1.25, 0.88, "kerolox")
	end
	return { parts = k.parts(), plumes = k.plumes, fire = "#ffc88a", heading = 28 }
end

local MAKE: { [string]: () -> Model } = { saturn = saturn, shuttle = shuttle, falcon = falcon, starship = starship, soyuz = soyuz }
local made: { [string]: Model } = {}

-- A kind's model (the first kind's, for one there isn't), built once.
function M.model(kind: string): Model
	local name = if MAKE[kind] then kind else M.KINDS[1]
	if not made[name] then
		made[name] = MAKE[name]()
	end
	return made[name]
end

return M
