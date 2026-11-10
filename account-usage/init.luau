local zeron = require("./zeron")("account-usage")
local Button = require("@ds/button")
local HoverCard = require("@ds/hover_card")
local Icon = require("@ds/icon")
local Text = require("@ds/text")
local enabled = zeron.setting("show")
local provider = zeron.setting("provider")
local interval = zeron.setting("refresh")
local remembered = zeron.store("last_provider", "codex")
local refresh = ui.state("account-usage.refresh", 0)
local BOOT = [[
from pathlib import Path
import runpy
runpy.run_path(str(Path.home() / ".zeron/plugins/account-usage/usage.py"), run_name="__main__")
]]

local function short_label(label)
    local lower = string.lower(label or "")
    if string.find(lower, "week", 1, true) then return "Wk" end
    if string.find(lower, "session", 1, true) then return "Session" end
    if string.find(lower, "day", 1, true) then return "Day" end
    return label or "Usage"
end

local function remaining_color(left)
    return if left <= 10 then "$danger" elseif left <= 25 then "$warning" else "$palette.teal.400"
end

local function dot(color)
    return ui.div { w = 4, h = 4, shrink = 0, rounded = "$radius.full", bg = color }
end

local function usage_card(data, busy)
    local windows = ui.computed(function()
        local d = data:get()
        return if d then d.windows or {} else {}
    end)
    local function status_color()
        local d = data:get()
        return if not d or #windows:get() == 0 then "$text.tertiary" elseif d.stale then "$warning" else "$success"
    end
    return HoverCard.Card {
        id = "account-usage-hover", w = 336, p = "$space.4", gap = "$space.4",
        ui.row { w_full = true, items = "center", gap = "$space.2",
            ui.row { color = "$text.secondary", Icon { name = "wallet", size = 20 } },
            ui.column { grow = 1, min_w = 0, gap = 2,
                Text { function() local d = data:get(); return if d then d.name or "Account usage" else "Account usage" end,
                    style = "label", truncate = true },
                ui.text { function() local d = data:get(); return if d and d.plan and d.plan ~= "" then d.plan else "Account limits" end,
                    text_size = 10, color = "$text.tertiary", truncate = true },
            },
            ui.row { items = "center", gap = "$space.1", dot(status_color),
                ui.text { function()
                    local d = data:get()
                    return if not d then "Loading" elseif #windows:get() == 0 then "Unavailable" elseif d.stale then "Cached" else "Live"
                end, text_size = 10, color = status_color },
            },
        },
        ui.each(windows, function(window)
            local color = remaining_color(window.left)
            return ui.column { w_full = true, gap = "$space.2",
                ui.row { w_full = true, items = "baseline", gap = "$space.2",
                    ui.text { window.label or "Usage", grow = 1, min_w = 0,
                        text_size = "$font.size.xs", weight = "$font.weight.medium", color = "$text.secondary", wrap = true },
                    ui.text { tostring(window.left) .. "%", tabular = true, text_size = 26, line_height = 30,
                        weight = "$font.weight.semibold", letter_spacing = -0.7, color = "$text.primary" },
                    ui.text { "left", text_size = 10, color = "$text.tertiary" },
                },
                ui.canvas { w_full = true, h = 4, label = (window.label or "Usage") .. " remaining",
                    draw = function(c, w, h)
                        c:rect(0, 0, w, h, "$zeron.switch.track", h / 2)
                        local fraction = math.clamp(window.left / 100, 0, 1)
                        if fraction > 0 then c:rect(0, 0, math.max(h, w * fraction), h, color, h / 2) end
                    end,
                },
                ui.show(window.resetText ~= nil, ui.row { items = "center", gap = "$space.1", color = "$text.tertiary",
                    Icon { name = "clock-circle", size = 11 },
                    ui.text { function()
                        local d = data:get()
                        return (if d and d.stale then "Reported reset · " else "Resets ") .. (window.resetText or "—")
                    end, text_size = 10, tabular = true, color = "$text.tertiary" },
                }),
            }
        end, { w_full = true, gap = "$space.4" }),
        ui.show(function() return #windows:get() == 0 end,
            Text { function() return if busy:get() then "Checking account usage…" else "No usage limits reported." end,
                style = "caption", tone = "secondary", wrap = true }),
        ui.show(function()
            local d = data:get()
            return d ~= nil and (d.stale or (d.note and d.note ~= ""))
        end, ui.text { function()
            local d = data:get()
            if not d then return "" end
            return if d.note and d.note ~= "" then d.note else "Last reported limits; current usage is unconfirmed."
        end, text_size = 10, color = "$text.tertiary", wrap = true }),
        ui.column { w_full = true, gap = "$space.2",
            ui.div { w_full = true, h = 1, bg = "$border.subtle" },
            ui.row { w_full = true, gap = "$space.2",
                ui.text { function()
                    local d = data:get()
                    return if busy:get() then "Refreshing…" elseif d and d.updatedText then "Updated " .. d.updatedText else "Account usage"
                end, grow = 1, min_w = 0, text_size = 10, color = "$text.tertiary", tabular = true, wrap = true },
                ui.text { "Click to refresh", shrink = 0, text_size = 10, color = "$text.tertiary" },
            },
            ui.text { "Account quota · separate from chat context", text_size = 9, color = "$text.tertiary" },
        },
    }
end

local function details(data)
    if not data then return "Reading account usage from Zeron…" end
    local lines = { (data.name or "Account") .. (if data.plan and data.plan ~= "" then " · " .. data.plan else "") }
    for _, w in data.windows or {} do
        table.insert(lines, w.label .. ": " .. tostring(w.left) .. "% remaining" .. (if w.resetText then " · resets " .. w.resetText else ""))
    end
    if data.updatedText then table.insert(lines, "Updated " .. data.updatedText) end
    if data.stale then table.insert(lines, "Cached usage; current limits have not been confirmed.") end
    if data.note and data.note ~= "" then table.insert(lines, data.note) end
    table.insert(lines, "Click to refresh. Quotas are account limits, separate from the chat’s context window.")
    return table.concat(lines, "\n")
end

ui.command {
    id = "refresh", title = "Refresh account usage", menu = "Account Usage",
    run = function() refresh:set(refresh:peek() + 1) end,
}

zeron.place {
    at = "#composer-toolbar",
    after = function()
        local session = zeron.live("session")
        local route = zeron.live("route")
        local data = ui.use_state(nil)
        local busy = ui.use_state(false)
        local query, chat, choice = "", "", "auto"
        local attempted = 0
        local generation = 0
        local force_after_cached = false

        local poll
        poll = function(force)
            if busy:peek() or enabled:peek() == false or not zeron.window(true).shown then return end
            busy:set(true)
            if force then attempted = ui.now() end
            local mine = generation
            zeron.run("python3", { "-c", BOOT }, {
                stdin = ui.json.encode({ chat = chat, provider = choice, fallback = remembered:peek(), force = force == true }),
                timeout = 40,
            }):after(function(result)
                busy:set(false)
                if mine ~= generation then poll(false); return end
                local ok, found = pcall(ui.json.decode, result.stdout or "")
                if result.status == 0 and ok and type(found) == "table" then
                    data:set(found)
                    if found.harness then remembered:set(found.harness) end
                elseif not data:peek() then
                    data:set({ windows = {}, note = "Could not read account usage from Zeron." })
                end
                local current = data:peek()
                zeron.set_status("show", {
                    badge = if current and #(current.windows or {}) > 0 then (if current.stale then "Cached" else "Live") else "Unavailable",
                    tone = if current and current.stale then "warning" else "neutral",
                    text = if current then details(current) else "Reading account usage…",
                })
                if force_after_cached then force_after_cached = false; poll(true) end
            end, function(_err)
                busy:set(false)
                if mine ~= generation then poll(false); return end
                if not data:peek() then data:set({ windows = {}, note = "Allow this plugin’s requested permissions in Settings → Plugins." }) end
            end)
        end

        ui.effect(function()
            local s, r = session(), route() or {}
            local new_chat = if s then s.id else (r.session or "")
            local new_choice = provider:get() or "auto"
            local showing = enabled:get() ~= false
            local key = new_chat .. "|" .. new_choice
            if key ~= query then
                query, chat, choice = key, new_chat, new_choice
                generation += 1
                data:set(nil)
                force_after_cached = true
            end
            if showing then poll(false) end
        end)
        ui.effect(function()
            refresh:get()
            if query ~= "" then poll(true) end
        end)
        ui.every(30000, function()
            if ui.now() - attempted >= (interval:peek() or 5) * 60000 then poll(true) end
        end)

        return ui.show(function() return enabled:get() ~= false end, ui.row {
            id = "account-usage-meter", items = "center", gap = "$space.1", shrink = 0,
            Button {
                tone = "ghost", size = "xs", label = "Remaining account usage",
                tooltip = usage_card(data, busy), tooltip_placement = { side = "top", align = "start", offset = 10 },
                on_click = function() poll(true) end,
                ui.row { items = "center", gap = "$space.2", color = "$text.tertiary",
                    Icon { name = "wallet", size = 12 },
                    ui.text { function() local d = data:get(); return if d then d.name or "Account" else "Usage" end,
                        text_size = 10, weight = "$font.weight.medium", color = "$text.secondary" },
                    ui.each(ui.computed(function()
                        local d = data:get()
                        local list = {}
                        for i, window in if d then d.windows or {} else {} do
                            if i <= 2 then table.insert(list, window) end
                        end
                        return list
                    end), function(window)
                        return ui.row { items = "center", gap = 4,
                            ui.text { short_label(window.label), text_size = 10, color = "$text.tertiary" },
                            ui.text { tostring(window.left) .. "%", text_size = 10, tabular = true,
                                color = function()
                                    local d = data:get()
                                    return if d and d.stale then "$text.secondary" else remaining_color(window.left)
                                end },
                        }
                    end, { direction = "row", items = "center", gap = "$space.2" }),
                    ui.show(function() local d = data:get(); return d ~= nil and #(d.windows or {}) > 0 end,
                        ui.text { "left", text_size = 10, color = "$text.tertiary" }),
                    ui.show(function() local d = data:get(); return d ~= nil and #(d.windows or {}) == 0 end,
                        ui.text { "unavailable", text_size = 10, color = "$text.tertiary" }),
                    ui.show(function() local d = data:get(); return d ~= nil and d.stale == true end,
                        ui.row { items = "center", gap = 4, dot("$warning"),
                            ui.text { "Cached", text_size = 9, color = "$text.tertiary" },
                        }),
                },
            },
        })
    end,
}
