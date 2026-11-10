-- Cosmos: a deep-space look for the whole window.
--
--   the sky        stars, a nebula in the accent's hues and a ringed planet,
--                  behind the sidebar and the title bar (`#shell-chats`,
--                  before) and, fainter, behind the conversation
--                  (`#shell-page-card`, after). Painted once on the GPU
--                  (space.luau): at rest it costs nothing.
--   twinkles       a few four-pointed stars that breathe, and now and then a
--                  shooting star. Only opacity and position move, on the
--                  compositor; none while the window is hidden or motion is
--                  reduced.
--   the rocket     on the message box's top edge: one of five real ones
--                  (a Saturn V, the Space Shuttle, a Falcon 9, Starship or
--                  a Soyuz: the "Which rocket" setting), in three
--                  dimensions (ship.luau, fleet.luau). It lifts off while
--                  the chat's agent is working and lands when it's done
--                  ("sessions.read": the session's status).
--   the moon       tonight's phase, after a chat's title.
--   the wallpaper  the view from low orbit behind a new chat
--                  (`#new-chat-background`, replaced: "ui.change"), once
--                  "Use as wallpaper" is on in this plugin's settings.
--
-- The colours themselves are a theme (Settings → Themes → Cosmos), not this
-- plugin's: a plugin draws, a theme colours.

local zeron = require("./zeron")("cosmos")
local space = require("./space")
local art = require("./art")
local ship = require("./ship")
local moon = require("./moon")
local motion = require("@ds/motion")

local stars_on = zeron.setting("stars")
local chat_stars = zeron.setting("chat_stars")
local nebula = zeron.setting("nebula")
local planet_on = zeron.setting("planet")
local twinkle_on = zeron.setting("twinkle")
local rocket_on = zeron.setting("rocket")
local rocket_kind = zeron.setting("rocket_kind")
local moon_on = zeron.setting("moon")
local orbit_motion = zeron.setting("orbit_motion")

local show_when = zeron.setting("show")

-- How many times a loop plays. A count, not `true`: in this Zeron an endless
-- loop a plugin starts never advances, and a counted one does. (Years, at
-- these loops' lengths.)
local LOOPS = 1000000

local NEBULA = { off = 0, soft = 0.6, vivid = 1 } :: { [string]: number }

-- Whether Cosmos shows at all: always, never, or (by default) only while
-- the window wears the Cosmos theme, known by its window colour, so
-- choosing another theme in Settings takes the sky away with it.
local MINE = { ["#060914"] = true, ["#eceefa"] = true }
local function active(): boolean
	local when = show_when:get()
	if when == "always" then
		return true
	elseif when == "never" then
		return false
	end
	local ok, window = pcall(ui.theme.get, "zeron.window")
	return ok and type(window) == "string" and MINE[string.lower(string.sub(window, 1, 7))] == true
end

-- Whether anything should move now.
local function lively(): boolean
	return twinkle_on:peek() ~= false and not motion.reduced_now() and zeron.window(true).shown
end

-- A node whose loop plays only while it can be seen (as Zeron's own
-- spinners do: a loop left running out of sight keeps the engine awake).
local function looping(props: any, start: (el: any) -> any): Node
	local held = setmetatable({}, { __mode = "v" }) :: { anim: any }
	props.on_visible = function(visible: boolean, el: any)
		if visible then
			if not held.anim and not motion.reduced_now() then
				held.anim = start(el)
			end
		elseif held.anim then
			held.anim:cancel()
			held.anim = nil
		end
	end
	return ui.div(props)
end

type Spot = { left: any?, right: any?, top: any?, bottom: any?, size: number, lo: number, hi: number, beat: number, wait: number }

-- A star that breathes.
local function Twinkle(s: Spot, ink: string): Node
	return looping({
		absolute = true,
		left = s.left,
		right = s.right,
		top = s.top,
		bottom = s.bottom,
		w = s.size,
		h = s.size,
		opacity = s.lo,
		pointer_events = "none",
		ui.svg { code = art.SPARKLE, w = s.size, h = s.size, tint = ink },
	}, function(el)
		return anime.animate(el, {
			opacity = { s.lo, s.hi },
			scale = { 0.7, 1.1 },
			duration = s.beat,
			delay = s.wait,
			loop = LOOPS,
			alternate = true,
			ease = "inOutSine",
			frameRate = 20,
		})
	end)
end

-- Where the sidebar's and the title bar's twinkles stand (the page's card
-- covers the rest of the window), and the conversation's, kept to its edges.
local AROUND: { Spot } = {
	{ left = 148, top = 13, size = 9, lo = 0.25, hi = 0.95, beat = 2600, wait = 0 },
	{ left = 26, top = "24%", size = 7, lo = 0.15, hi = 0.8, beat = 3400, wait = 900 },
	{ left = 188, top = "37%", size = 11, lo = 0.2, hi = 0.9, beat = 4200, wait = 300 },
	{ left = 92, top = "52%", size = 6, lo = 0.15, hi = 0.7, beat = 3000, wait = 1700 },
	{ left = 212, top = "66%", size = 8, lo = 0.2, hi = 0.85, beat = 3800, wait = 600 },
	{ left = 150, bottom = 118, size = 12, lo = 0.25, hi = 1, beat = 4600, wait = 1200 },
	{ left = 44, bottom = 190, size = 7, lo = 0.15, hi = 0.75, beat = 2900, wait = 2100 },
	{ left = "38%", top = 9, size = 7, lo = 0.15, hi = 0.75, beat = 3600, wait = 1500 },
	{ right = "27%", top = 15, size = 8, lo = 0.2, hi = 0.85, beat = 3100, wait = 400 },
}
local WITHIN: { Spot } = {
	{ right = 30, top = 64, size = 10, lo = 0.12, hi = 0.6, beat = 3600, wait = 200 },
	{ left = 26, top = 176, size = 7, lo = 0.1, hi = 0.5, beat = 4200, wait = 1300 },
	{ right = 64, top = 372, size = 6, lo = 0.1, hi = 0.45, beat = 3000, wait = 800 },
	{ left = 44, top = 560, size = 8, lo = 0.1, hi = 0.5, beat = 4800, wait = 1900 },
	{ right = 22, top = 610, size = 7, lo = 0.1, hi = 0.5, beat = 3300, wait = 2500 },
}

-- A sky: the shader's stars and nebula, twinkles over them and a shooting
-- star now and then, starting somewhere in the box's left `span` points (or
-- anywhere, without one).
type SkyProps = {
	stars: number,
	cloud: number,
	light: boolean,
	seed: number,
	planet: boolean?,
	fade: number?,
	spots: { Spot }?,
	span: number?,
	dim: number?,
	-- How much of the box's height shows (a hung box is taller than its card).
	depth: number?,
}
local function Sky(props: SkyProps): Node
	local box = ui.ref()
	local streak = ui.ref()
	local ink = if props.light then "#3a3f8f" else "#ffffff"
	local kids: { any } = {}
	if props.spots then
		for _, s in props.spots do
			table.insert(kids, Twinkle(s, ink))
		end
		-- (Every few seconds, sometimes: one crosses.)
		ui.every(6500, function()
			local el = streak:peek()
			local w, h = box.width or 0, math.min(box.height or 0, props.depth or math.huge)
			if not el or w < 160 or h < 160 or not lively() or math.random() > 0.4 then
				return
			end
			local x = math.random() * math.min(props.span or w, w) * 0.8
			local y = 24 + math.random() * h * 0.45
			local far = 170 + math.random() * 150
			anime.animate(el, {
				x = { x, x + far * 0.9 },
				y = { y, y + far * 0.44 },
				opacity = { 0, props.dim or 1, props.dim or 1, 0 },
				duration = 620 + far * 1.4,
				ease = "outQuad",
			})
		end)
		table.insert(kids, ui.div {
			ref = streak,
			absolute = true,
			left = -96,
			top = 0,
			opacity = 0,
			rotate = 26,
			origin = { 1, 0.5 },
			pointer_events = "none",
			ui.svg { code = art.STREAK, w = 96, h = 4.8, tint = if props.light then ink else nil },
		})
	end
	return ui.div {
		ref = box,
		w_full = true,
		h_full = true,
		relative = true,
		overflow = "hidden",
		pointer_events = "none",
		aria_hidden = true,
		bg_shader = space.SKY,
		shader_params = {
			"$accent",
			{ props.stars, props.cloud, if props.light then 1 else 0, props.seed },
			if props.planet then { 62, 30, 96, 1 } else { 0, 0, 0, 0 },
			{ props.fade or 0, 0, 0, 0 },
		},
		table.unpack(kids),
	}
end

-- A theme colour at another strength: "#rrggbb" and two more digits.
local function wash(token: string, alpha: string, fallback: string): string
	local ok, c = pcall(ui.theme.get, token)
	return (if ok and type(c) == "string" and #c >= 7 then string.sub(c, 1, 7) else fallback) .. alpha
end

-- Whether the window's cards are glass (Appearance's frosted window): then
-- what is drawn behind everything already shows through them, and the
-- conversation needs a veil over it rather than a second drawing.
local function glassy(): boolean
	local ok, c = pcall(ui.theme.get, "surface.raised")
	if not ok or type(c) ~= "string" or #c < 9 then
		return false
	end
	return (tonumber(string.sub(c, 8, 9), 16) or 255) < 200
end

local EDGES = { absolute = true, left = 0, right = 0, top = 0, bottom = 0, pointer_events = "none" }

-- A card has no `relative` box of its own for a placed node to measure
-- from, so what goes behind one stands at its top, as wide as it, and hangs
-- down past any window's height: the card's own edge cuts it off.
local TALL = 3200
local function Hang(inner: Node): Node
	return ui.div {
		relative = true,
		w_full = true,
		h = 0,
		overflow = "visible",
		pointer_events = "none",
		ui.div { absolute = true, left = 0, right = 0, top = 0, h = TALL, pointer_events = "none", inner },
	}
end


-- What a sky is built from, as one key: built again as a setting changes.
local function sky_key(): string
	return table.concat({
		tostring(active()),
		tostring(stars_on:get() ~= false),
		tostring(chat_stars:get() ~= false),
		tostring(nebula:get()),
		tostring(planet_on:get() ~= false),
		tostring(twinkle_on:get() ~= false and not motion.reduced()),
		tostring(glassy()),
	}, "|")
end

-- Behind everything: the sidebar's and the title bar's sky.
zeron.place {
	at = "#shell-chats",
	before = function(): Node
		local light = zeron.context("appearance") == "light"
		return ui.presence(sky_key, function(_key: string): Node
			local stars = if stars_on:peek() ~= false then 1 else 0
			local cloud = NEBULA[nebula:peek()] or 0.6
			local planet = planet_on:peek() ~= false
			if string.sub(_key, 1, 4) ~= "true" or (stars == 0 and cloud == 0 and not planet) then
				return ui.div {}
			end
			return Sky {
				stars = stars,
				cloud = cloud,
				light = light,
				seed = 0.37,
				planet = planet,
				spots = if stars == 1 and twinkle_on:peek() ~= false and not motion.reduced_now() then AROUND else nil,
				span = 250,
			}
		end, table.clone(EDGES))
	end,
}

-- Behind the conversation, over its card: the same sky, fainter.
zeron.place {
	at = "#shell-page-card",
	after = function(): Node
		local light = zeron.context("appearance") == "light"
		return ui.presence(sky_key, function(_key: string): Node
			if string.sub(_key, 1, 4) ~= "true" or chat_stars:peek() == false then
				return ui.div {}
			end
			local stars = if stars_on:peek() ~= false then 0.36 else 0
			local cloud = (NEBULA[nebula:peek()] or 0.6) * 0.5
			if stars == 0 and cloud == 0 then
				return ui.div {}
			end
			-- (Glass cards: the window's sky is already behind this one, so
			-- only veil it a little where you read, and keep the twinkles.)
			local spots = if stars > 0 and twinkle_on:peek() ~= false and not motion.reduced_now() then WITHIN else nil
			if glassy() then
				return Hang(ui.div {
					w_full = true,
					h_full = true,
					bg = wash("zeron.window", "66", "#060914"),
					Sky { stars = 0, cloud = 0, light = light, seed = 0.83, spots = spots, dim = 0.55, depth = 700 },
				})
			end
			return Hang(Sky { stars = stars, cloud = cloud, light = light, seed = 0.83, spots = spots, dim = 0.55, depth = 700 })
		end, { w_full = true })
	end,
}

-- The rocket on the message box: the one chosen in settings, in three
-- dimensions (ship.luau), standing at the box's top right (this node is the
-- box's next sibling in its row, so its corner is the box's). While the
-- open chat's agent works it lights its engines, climbs and holds there,
-- swaying; when the agent stops it levels out, comes down and cuts them as
-- it touches.
local PAD = { w = 56, h = 128 }
-- (The points a unit of the scene is, and how far under the ground the
-- scene's box reaches: room for the feet nearest the viewer.)
local UNIT = 22
local GROUND = 0.3
local CLIMB_MS = 1100
zeron.place {
	at = "#chat-composer",
	after = function(): Node
		if not ship.available then
			return ui.div {}
		end
		-- (The chat the window shows: the message box stands over the page,
		-- beside what provides its session, so the route says which.)
		local route = zeron.live("route")
		local light = zeron.context("appearance") == "light"
		local working = ui.computed(function(): boolean
			if rocket_on:get() == false or not active() then
				return false
			end
			local r = route()
			local id = if type(r) == "table" then r.session else nil
			if type(id) ~= "string" then
				return false
			end
			local now = zeron.context_of("session", id)
			return type(now) == "table" and now.status == "working"
		end)
		return ui.div {
			relative = true,
			w = 0,
			h = 0,
			overflow = "visible",
			pointer_events = "none",
			aria_hidden = true,
			ui.show(
				function(): boolean
					return rocket_on:get() ~= false and active()
				end,
				-- (Built again as another rocket is chosen or Reduce Motion
				-- changes: a scene's meshes and how long it climbs are its
				-- own.)
				ui.presence(function(): string
					return `{rocket_kind:get()}|{motion.reduced()}`
				end, function(_key: string): Node
					local moves = not motion.reduced_now()
					local fly, burn = ui.use_state(0), ui.use_state(0)
					local bob, turn, flick = ui.use_state(0.5), ui.use_state(0.5), ui.use_state(0)
					local flying = false
					-- Each change of course is a turn of its own: what an
					-- earlier one left waiting does nothing once it's over.
					local course = 0
					local function later(ms: number, run: () -> ())
						local mine = course
						anime.createTimer {
							duration = ms,
							onComplete = function()
								if mine == course then
									run()
								end
							end,
						}
					end
					-- A state swung between its two ends, one way each `ms`,
					-- for as long as this course lasts (still while the
					-- window is hidden).
					local function swing(state: any, ms: number)
						local side = 1
						local function step()
							if zeron.window(true).shown then
								state:set(side)
								side = 1 - side
							end
							later(ms, step)
						end
						step()
					end
					ui.effect(function()
						local on = working:get()
						if on == flying then
							return
						end
						flying = on
						course += 1
						if on then
							burn:set(1)
							if not moves then
								fly:set(1)
								return
							end
							later(260, function()
								fly:set(1)
								swing(flick, 150)
								swing(bob, 1700)
								later(CLIMB_MS * 0.6, function()
									swing(turn, 2300)
								end)
							end)
						else
							bob:set(0.5)
							turn:set(0.5)
							if not moves then
								fly:set(0)
								burn:set(0)
								return
							end
							later(800, function()
								fly:set(0)
								later(CLIMB_MS - 120, function()
									burn:set(0)
								end)
							end)
						end
					end)
					ui.on_cleanup(function()
						course += 1
					end)
					return ship.scene {
						kind = tostring(rocket_kind:peek()),
						w = PAD.w,
						h = PAD.h,
						view = PAD.h / UNIT,
						ground = GROUND,
						fly = fly,
						burn = burn,
						bob = bob,
						turn = turn,
						flick = flick,
						climb = 18 / UNIT,
						climb_ms = if moves then CLIMB_MS else 1,
						light = light,
					}
				end, {
					absolute = true,
					right = 19,
					-- (Its feet on the box's edge: the ground is that far up
					-- the scene.)
					bottom = -math.floor(GROUND * UNIT + 0.5) + 1,
					w = PAD.w,
					h = PAD.h,
					pointer_events = "none",
				})
			),
		}
	end,
}

-- Tonight's moon, after a chat's title. Its phase is worked out from the
-- date (moon.luau): pointing at it says which, and how much is lit.
zeron.place {
	at = "#page-title",
	after = function(): Node
		local now = ui.use_state(os.time())
		ui.every(30 * 60 * 1000, function()
			now:set(os.time())
		end)
		local function words(): string
			local p = moon.phase(now:get())
			return zeron.s("moon.tip", { phase = zeron.s("moon." .. p.name), lit = math.floor(p.lit * 100 + 0.5) })
		end
		return ui.show(
			function(): boolean
				return moon_on:get() ~= false and active()
			end,
			ui.row {
				id = "cosmos-moon",
				items = "center",
				justify = "center",
				w = 22,
				h = 22,
				shrink = 0,
				rounded = "$radius.sm",
				hover = { bg = "$hover" },
				tooltip = words(),
				on_click = function()
					zeron.toast(words())
				end,
				ui.canvas {
					w = 14,
					h = 14,
					label = words,
					draw = function(c: any, w: number, _h: number)
						moon.draw(c, 0, 0, w, moon.phase(now:get()).turn, "$text.primary", "$border.strong", "$text.tertiary")
					end,
				},
			}
		)
	end,
}

-- A new chat's wallpaper: the view from low orbit, its stars, moon and
-- horizon each moving a little against the pointer. Shown once "Use as
-- wallpaper" is on in this plugin's settings.
local last_look = { x = 0, y = 0 }
zeron.place {
	at = "#new-chat-background",
	fill = true,
	replace = function(): Node
		local pointer = zeron.live("pointer")
		return ui.presence(function(): string
			return `{if motion.reduced() then "still" else orbit_motion:get()}`
		end, function(mode: string): Node
			local fps = if mode == "lively" then 30 elseif mode == "calm" then 12 else 0
			local scene = ui.ref()
			if fps > 0 then
				ui.effect(function()
					local p = pointer()
					local el = scene:get()
					if not el or type(p) ~= "table" then
						return
					end
					local x, y = (p.x or 0.5) - 0.5, (p.y or 0.5) - 0.5
					if math.abs(x - last_look.x) < 0.008 and math.abs(y - last_look.y) < 0.008 then
						return
					end
					last_look = { x = x, y = y }
					anime.animate(el, { shaderParam4 = x, shaderParam5 = y, duration = 900, ease = "out(3)" })
				end)
			end
			return looping({
				ref = scene,
				id = "cosmos-orbit",
				absolute = true,
				left = 0,
				right = 0,
				top = 0,
				bottom = 0,
				aria_hidden = true,
				bg = "#03040b",
				bg_shader = space.ORBIT,
				shader_params = { "$accent", { last_look.x, last_look.y, if fps > 0 then 22 else 0, if fps > 0 then 1 else 0 }, { 0, 0.37, 0, 0 }, { 0, 0, 0, 0 } },
			}, function(el)
				if fps == 0 then
					return nil
				end
				-- (An hour of it, then again: the clouds drift, the stars beat.)
				return anime.animate(el, { shaderTime = { 0, 3600 }, duration = 3600000, ease = "linear", loop = LOOPS, frameRate = fps })
			end)
		end, { w_full = true, h_full = true })
	end,
}
