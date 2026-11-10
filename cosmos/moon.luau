-- The Moon as it is tonight: its phase from the date, and a drawing of it.

local M = {}

-- A mean synodic month, in days, and a new moon to count from
-- (2000-01-06 18:14 UTC).
local SYNODIC = 29.530588853
local NEW_MOON = 947182440

export type Phase = {
	-- 0 new, 0.25 first quarter, 0.5 full, 0.75 last quarter.
	turn: number,
	-- How much of its face is lit, 0 to 1.
	lit: number,
	-- "new", "waxing_crescent", "first_quarter", "waxing_gibbous", "full",
	-- "waning_gibbous", "last_quarter", "waning_crescent".
	name: string,
}

function M.phase(at: number?): Phase
	local days = ((at or os.time()) - NEW_MOON) / 86400
	local turn = (days / SYNODIC) % 1
	local lit = (1 - math.cos(2 * math.pi * turn)) / 2
	local name
	if turn < 0.03 or turn >= 0.97 then
		name = "new"
	elseif turn < 0.22 then
		name = "waxing_crescent"
	elseif turn < 0.28 then
		name = "first_quarter"
	elseif turn < 0.47 then
		name = "waxing_gibbous"
	elseif turn < 0.53 then
		name = "full"
	elseif turn < 0.72 then
		name = "waning_gibbous"
	elseif turn < 0.78 then
		name = "last_quarter"
	else
		name = "waning_crescent"
	end
	return { turn = turn, lit = lit, name = name }
end

-- Draw it in a canvas, `size` points across with its top left at (x, y):
-- its dark face in `shade`, what is lit in `ink` (seen from the north: it
-- waxes from the right).
function M.draw(c: any, x: number, y: number, size: number, turn: number, ink: string, shade: string, rim: string?)
	local r = size / 2
	local cx, cy = x + r, y + r
	c:circle(cx, cy, r, shade)
	-- (A thin rim, so even a new moon reads as a moon.)
	if rim then
		c:stroke(ui.path():arc(cx, cy, r - 0.5, 0, 360):close(), rim, 1)
	end
	local k = math.cos(2 * math.pi * turn)
	-- (Nothing to show of a new moon; all of a full one.)
	if k > 0.995 then
		return
	end
	if k < -0.995 then
		c:circle(cx, cy, r, ink)
		return
	end
	local side = if turn <= 0.5 then 1 else -1
	local K = 0.5523 * r
	-- The lit limb, top to bottom, then back up along the terminator: half
	-- an ellipse as wide as the phase's cosine.
	local a = side * r * k
	local ka = 0.5523 * a
	local path = ui.path()
		:move(cx, cy - r)
		:cubic(cx + side * K, cy - r, cx + side * r, cy - K, cx + side * r, cy)
		:cubic(cx + side * r, cy + K, cx + side * K, cy + r, cx, cy + r)
		:cubic(cx + ka, cy + r, cx + a, cy + K, cx + a, cy)
		:cubic(cx + a, cy - K, cx + ka, cy - r, cx, cy - r)
		:close()
	c:fill(path, ink)
end

return M
