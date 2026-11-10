local zeron = require("./zeron")("pixel-walker")
local sprite = require("./sprite")
local motion = require("@ds/motion")
local walking = zeron.setting("walking")
local speed = zeron.setting("speed")
local size = zeron.setting("size")
local companions = zeron.setting("subagents")
local BOOT = [[
from pathlib import Path
import runpy
runpy.run_path(str(Path.home() / ".zeron/plugins/pixel-walker/activity.py"), run_name="__main__")
]]
local HATS = {
    "$palette.blue.400", "$palette.violet.400", "$palette.amber.400",
    "$palette.green.400", "$palette.cyan.400", "$palette.pink.400",
}

local function seed_of(id)
    local seed = 17
    for i = 1, #id do seed = (seed * 33 + string.byte(id, i)) % 65521 end
    return seed
end

zeron.place {
    at = "#titlebar-actions-island",
    after = function()
        local route = zeron.live("route")
        local active = ui.use_state({})
        local redraw = ui.use_state(0)
        local actors, by_id = {}, {}
        local width, current_chat = 0, ""
        local last, busy = ui.now(), false

        local function scale()
            return if size:peek() == "tiny" then 1 else 2
        end

        local function poll()
            if busy or current_chat == "" or companions:peek() == false or not zeron.window(true).shown then return end
            busy = true
            local asked = current_chat
            zeron.run("python3", { "-c", BOOT, asked }, { timeout = 8 }):after(function(result)
                busy = false
                if asked ~= current_chat or companions:peek() == false then return end
                local ok, data = pcall(ui.json.decode, result.stdout or "")
                if result.status ~= 0 or not ok or type(data) ~= "table" or data.error then
                    active:set({})
                    zeron.set_status("subagents", { badge = "Unavailable", tone = "warning", text = "Could not read local subagent activity. Check the plugin’s requested permissions." })
                    return
                end
                local ids = data.active or {}
                active:set(ids)
                zeron.set_status("subagents", {
                    badge = tostring(#ids) .. " running", tone = "neutral",
                    text = "One extra walker for each running subagent of the open chat. Finished subagents leave automatically.",
                })
            end, function(_err)
                busy = false
                if asked ~= current_chat then return end
                active:set({})
                zeron.set_status("subagents", { badge = "Needs access", tone = "warning", text = "Allow the plugin’s requested permissions to read subagent activity." })
            end)
        end

        ui.effect(function()
            local r = route() or {}
            local enabled = companions:get() ~= false
            current_chat = if enabled then (r.session or "") else ""
            active:set({})
            if current_chat == "" then
                zeron.set_status("subagents", nil)
            else
                poll()
            end
        end)
        ui.every(2500, poll)

        -- Keep each fellow's position, pace and colour while his agent is
        -- present. Updating the activity feed never restarts their walks.
        ui.effect(function()
            local ids = { "main" }
            if companions:get() ~= false then
                for _, id in active:get() do table.insert(ids, id) end
            end
            local next_actors, next_by_id = {}, {}
            for _, id in ids do
                local a = by_id[id]
                if not a then
                    local seed = seed_of(id)
                    local primary = id == "main"
                    a = {
                        x = 0, initialized = false,
                        start = if primary then 0.2 else (0.08 + (seed % 83) / 100),
                        direction = if primary or seed % 2 == 0 then 1 else -1,
                        elapsed = (seed % 12) / 10, pause = 0,
                        pace = if primary then 1 else 0.82 + (seed % 37) / 100,
                        hat = if primary then nil else HATS[seed % #HATS + 1],
                    }
                    if width > 0 then
                        a.x = math.max(0, width - sprite.width * scale()) * a.start
                        a.initialized = true
                    end
                end
                next_by_id[id] = a
                table.insert(next_actors, a)
            end
            actors, by_id = next_actors, next_by_id
            redraw:set(redraw:peek() + 1)
        end)

        ui.every(80, function()
            local now = ui.now()
            local dt = math.min(0.12, math.max(0, (now - last) / 1000))
            last = now
            if width <= 0 or walking:peek() == false or motion.reduced_now() or not zeron.window(true).shown then return end
            local reach = math.max(0, width - sprite.width * scale())
            for _, a in actors do
                if not a.initialized then a.x = reach * a.start; a.initialized = true end
                a.x = math.clamp(a.x, 0, reach)
                a.elapsed += dt * a.pace
                if a.pause > 0 then
                    a.pause -= dt
                    if a.pause <= 0 then a.direction = -a.direction end
                elseif reach > 0 then
                    a.x += a.direction * (speed:peek() or 40) * a.pace * dt
                    if a.x >= reach then a.x = reach; a.pause = 0.7
                    elseif a.x <= 0 then a.x = 0; a.pause = 0.7 end
                end
            end
            redraw:set(redraw:peek() + 1)
        end)

        return ui.canvas {
            id = "pixel-walker",
            absolute = true,
            left = 180, right = 48, top = 6, h = 36,
            pointer_events = "none", aria_hidden = true,
            on_resize = function(box)
                width = box.w
                local reach = math.max(0, width - sprite.width * scale())
                for _, a in actors do
                    if not a.initialized then a.x = reach * a.start; a.initialized = true end
                    a.x = math.clamp(a.x, 0, reach)
                end
            end,
            draw = function(c, w, h)
                redraw:get()
                local s = if size:get() == "tiny" then 1 else 2
                local moving = walking:get() ~= false and not motion.reduced()
                for _, a in actors do
                    local frame = if moving and a.pause <= 0 then math.floor(a.elapsed / 0.12) % 4 + 1 else 2
                    local px = math.floor(math.clamp(a.x, 0, math.max(0, w - sprite.width * s)) / s) * s
                    local bob = if moving and a.pause <= 0 and (frame == 2 or frame == 4) then s else 0
                    local py = h - sprite.height * s - 1 - bob
                    for _, span in sprite.frames[frame] do
                        local column = if a.direction > 0 then span.x else sprite.width - span.x - span.w
                        local color = if a.hat and (span.color == "h" or span.color == "t") then a.hat else sprite.palette[span.color]
                        c:rect(px + column * s, py + span.y * s, span.w * s, s, color)
                    end
                end
            end,
        }
    end,
}
