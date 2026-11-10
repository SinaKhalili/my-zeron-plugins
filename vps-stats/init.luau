local zeron = require("./zeron")("vps-stats")
local collector = require("./collector")
local Button = require("@ds/button")
local Text = require("@ds/text")
local Stat = require("@ds/stat")
local Settings = require("@ds/settings")
local EmptyState = require("@ds/empty_state")
local Chart = require("@ds/chart")
local HoverCard = require("@ds/hover_card")
local Icon = require("@ds/icon")

local host_setting = zeron.setting("host")
local disk_setting = zeron.setting("disk")
local interval_setting = zeron.setting("interval")
local monitor_setting = zeron.setting("monitor")
local bar_setting = zeron.setting("bar")
local sample = ui.state("vps-stats.sample", nil)
local history = ui.state("vps-stats.history", {})
local issue = ui.state("vps-stats.issue", "")
local busy = ui.state("vps-stats.busy", false)
local received = ui.state("vps-stats.received", 0)
local clock = ui.state("vps-stats.clock", ui.now())
local last_attempt, generation = 0, 0
local current_host, current_disk, signature = "ovh", "/", ""

local function percent(n)
    return if type(n) == "number" then string.format("%.0f%%", n) else "—"
end

local function bytes(n)
    if type(n) ~= "number" then return "—" end
    if n >= 1024 ^ 3 then return string.format("%.1f GiB", n / 1024 ^ 3) end
    if n >= 1024 ^ 2 then return string.format("%.1f MiB", n / 1024 ^ 2) end
    if n >= 1024 then return string.format("%.0f KiB", n / 1024) end
    return string.format("%.0f B", n)
end

local function uptime(seconds)
    if type(seconds) ~= "number" then return "—" end
    local days = math.floor(seconds / 86400)
    local hours = math.floor(seconds % 86400 / 3600)
    local minutes = math.floor(seconds % 3600 / 60)
    return if days > 0 then `{days}d {hours}h` else `{hours}h {minutes}m`
end

local function age()
    return math.max(0, math.floor((clock:get() - received:get()) / 1000))
end

local function fresh()
    return sample:get() ~= nil and issue:get() == "" and monitor_setting:get() ~= false
        and age() <= math.max(30, (interval_setting:get() or 10) * 3)
end

local function state_text()
    if monitor_setting:get() == false then return "Paused" end
    if issue:get() ~= "" then return issue:get() end
    if received:get() == 0 then return "Connecting to " .. current_host .. "…" end
    return "Updated " .. tostring(age()) .. "s ago" .. (if fresh() then "" else " · stale")
end

local function fail(text)
    issue:set(text)
    zeron.set_status("host", { badge = "Unavailable", tone = "warning", text = text })
end

local function validate(data)
    if type(data) ~= "table" or type(data.at) ~= "number" or type(data.host) ~= "string" then return false end
    for _, key in { "memory", "swap", "disk", "network", "load" } do
        if type(data[key]) ~= "table" then return false end
    end
    return type(data.memory.total) == "number" and type(data.memory.used) == "number"
        and type(data.disk.total) == "number" and type(data.disk.used) == "number"
end

local function collect()
    if busy:peek() or monitor_setting:peek() == false or not zeron.window(true).shown then return end
    if current_host == "" or string.sub(current_host, 1, 1) == "-" or not string.match(current_host, "^[%w_.@:%[%]%-]+$") then
        fail("Choose a valid SSH host or host alias in Settings → VPS Stats.")
        return
    end
    if string.sub(current_disk, 1, 1) ~= "/" or string.find(current_disk, "\0", 1, true) then
        fail("Choose an absolute disk path, such as / or /home.")
        return
    end
    last_attempt = ui.now()
    busy:set(true)
    local mine = generation
    -- The command is fixed; the disk path is JSON data inside the Python
    -- script, never interpolated into a shell command.
    local script = "import json\nDISK_PATH = json.loads(" .. ui.json.encode(ui.json.encode(current_disk)) .. ")\n" .. collector
    zeron.run("ssh", {
        "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=7",
        "-o", "StrictHostKeyChecking=yes", "-o", "ForwardAgent=no",
        current_host, "python3", "-",
    }, { stdin = script, timeout = 15 }):after(function(result)
        busy:set(false)
        if mine ~= generation then collect(); return end
        if result.status ~= 0 then
            local err = string.lower(result.stderr or "")
            if string.find(err, "host key", 1, true) or string.find(err, "identification has changed", 1, true) then
                fail("SSH host key verification failed. Check this host’s key in your SSH setup.")
            elseif string.find(err, "permission denied", 1, true) then
                fail("SSH authentication failed. This host must connect without a password prompt.")
            elseif string.find(err, "python3", 1, true) and string.find(err, "not found", 1, true) then
                fail("Python 3 is unavailable on this VPS.")
            else
                fail("VPS unavailable. Retrying automatically.")
            end
            return
        end
        local ok, data = pcall(ui.json.decode, result.stdout or "")
        if not ok or type(data) ~= "table" then fail("The VPS returned an unreadable sample."); return end
        if data.error then fail(data.error); return end
        if not validate(data) then fail("The VPS returned an incomplete sample."); return end
        ui.batch(function()
            sample:set(data)
            received:set(ui.now())
            clock:set(ui.now())
            issue:set("")
            local points = table.clone(history:peek())
            table.insert(points, { at = ui.now() / 1000, cpu = data.cpu, memory = data.memory.percent, disk = data.disk.percent })
            while #points > 120 do table.remove(points, 1) end
            history:set(points)
        end)
        zeron.set_status("host", { badge = "Connected", tone = "success", text = data.host .. " · read-only metrics over SSH" })
    end, function(_err)
        busy:set(false)
        if mine ~= generation then collect(); return end
        fail("Could not start SSH. Allow this plugin’s requested permission in Settings → Plugins.")
    end)
end

ui.effect(function()
    local host = string.match(host_setting:get() or "ovh", "^%s*(.-)%s*$") or ""
    local disk = disk_setting:get() or "/"
    local key = host .. "|" .. disk
    local enabled = monitor_setting:get() ~= false
    if signature ~= key then
        signature, current_host, current_disk = key, host, disk
        generation += 1
        sample:set(nil)
        history:set({})
        received:set(0)
        issue:set("")
    end
    if enabled then collect() end
end)

ui.every(1000, function()
    if not zeron.window(true).shown then return end
    clock:set(ui.now())
    if ui.now() - last_attempt >= (interval_setting:peek() or 10) * 1000 then collect() end
end)
ui.command { id = "refresh", title = "Refresh VPS stats", menu = "VPS Stats", run = collect }

local colors = { cpu = "$palette.blue.400", memory = "$palette.violet.400", disk = "$palette.amber.400" }

-- Charts accept visual color names or hex; resolve our shared theme hues
-- here so their legend and lines match the native meters in every theme.
local function chart_color(key)
    ui.theme.current:get()
    return ui.theme.get(string.sub(colors[key], 2)) or "chart1"
end

local function value_of(key)
    local d = sample:get()
    if not d then return nil end
    return if key == "cpu" then d.cpu else d[key].percent
end

local function status_color()
    return if fresh() then "$success" elseif received:get() > 0 or issue:get() ~= "" then "$warning" else "$text.tertiary"
end

local function dot(color, size)
    return ui.div { w = size or 5, h = size or 5, shrink = 0, rounded = "$radius.full", bg = color }
end

local function meter(key, height)
    return ui.canvas {
        w_full = true, h = height or 3, aria_hidden = true,
        draw = function(c, w, h)
            c:rect(0, 0, w, h, "$zeron.switch.track", h / 2)
            local v = math.clamp((value_of(key) or 0) / 100, 0, 1)
            if v > 0 then c:rect(0, 0, math.max(h, w * v), h, colors[key], h / 2) end
        end,
    }
end

local function compact_metric(key, title, detail)
    return ui.column {
        grow = 1, min_w = 0, gap = "$space.2",
        ui.row { items = "center", gap = "$space.1", dot(colors[key]),
            Text { title, style = "caption", tone = "secondary" },
        },
        ui.text { function() return percent(value_of(key)) end, text_size = 25, line_height = 29,
            weight = "$font.weight.semibold", letter_spacing = -0.7, color = "$text.primary", tabular = true },
        meter(key),
        ui.text { detail, text_size = 10, color = "$text.tertiary", tabular = true, truncate = true },
    }
end

local function small_detail(label, value)
    return ui.column {
        grow = 1, min_w = 0, gap = "$space.1",
        ui.text { label, text_size = 10, color = "$text.tertiary" },
        ui.text { value, text_size = "$font.size.xs", color = "$text.secondary", tabular = true, truncate = true },
    }
end

local function hover_card()
    return HoverCard.Card {
        id = "vps-stats-hover", w = 360, p = "$space.4", gap = "$space.4",
        ui.row {
            w_full = true, items = "center", gap = "$space.2",
            ui.row { color = "$text.secondary", Icon { name = "remote-server", size = 20 } },
            ui.column { grow = 1, min_w = 0, gap = 2,
                Text { function() local d = sample:get(); return if d then d.host else current_host end,
                    style = "label", truncate = true },
                ui.text { function() local d = sample:get(); return if d then tostring(d.cores) .. " vCPU · Linux VPS" else "Linux VPS" end,
                    text_size = 10, color = "$text.tertiary" },
            },
            ui.row { items = "center", gap = "$space.1", dot(status_color),
                ui.text { function() return if fresh() then "Live" elseif monitor_setting:get() == false then "Paused" else "Offline" end,
                    text_size = 10, color = status_color },
            },
        },
        ui.show(function() return sample:get() == nil end,
            Text { state_text, style = "caption", tone = "secondary", wrap = true }),
        ui.show(function() return sample:get() ~= nil end, ui.column {
            w_full = true, gap = "$space.4",
            ui.row { w_full = true, gap = "$space.4",
                compact_metric("cpu", "CPU", function() local d = sample:get(); return if d then tostring(d.processes) .. " processes" else "—" end),
                compact_metric("memory", "Memory", function() local d = sample:get(); return if d then bytes(d.memory.used) .. " used" else "—" end),
                compact_metric("disk", "Disk", function() local d = sample:get(); return if d then bytes(d.disk.available) .. " free" else "—" end),
            },
            ui.column { w_full = true, gap = "$space.2",
                ui.row { w_full = true, items = "center",
                    ui.text { "RECENT ACTIVITY", grow = 1, text_size = 9, weight = "$font.weight.medium", letter_spacing = 0.7, color = "$text.tertiary" },
                    ui.text { function()
                        local points = history:get()
                        local seconds = if #points > 1 then points[#points].at - points[math.max(1, #points - 39)].at else 0
                        return if seconds >= 60 then tostring(math.floor(seconds / 60)) .. " min" else "Just started"
                    end, text_size = 9, color = "$text.tertiary" },
                },
                ui.canvas { w_full = true, h = 54, label = "Recent CPU, memory and disk usage",
                    draw = function(c, w, h)
                        local points = history:get()
                        for _, fraction in { 0, 0.5, 1 } do c:rect(0, 3 + fraction * (h - 6), w, 0.5, "$border.subtle") end
                        local first = math.max(1, #points - 39)
                        local count = #points - first + 1
                        if count < 1 then return end
                        for _, key in { "disk", "memory", "cpu" } do
                            local path = ui.path()
                            for i = first, #points do
                                local x = if count == 1 then w - 2 else 2 + (i - first) / (count - 1) * (w - 4)
                                local y = h - 3 - math.clamp((points[i][key] or 0) / 100, 0, 1) * (h - 6)
                                path = if i == first then path:move(x, y) else path:line(x, y)
                                if i == #points then c:circle(x, y, 2, colors[key]) end
                            end
                            if count > 1 then c:stroke(path, colors[key], 1.5, { join = "round", cap = "round" }) end
                        end
                    end,
                },
            },
            ui.row { w_full = true, gap = "$space.4",
                small_detail("NETWORK ↓ / ↑", function() local d = sample:get(); return if d then bytes(d.network.down) .. "/s / " .. bytes(d.network.up) .. "/s" else "—" end),
                small_detail("UPTIME", function() local d = sample:get(); return if d then uptime(d.uptime) else "—" end),
            },
            ui.row { w_full = true, gap = "$space.4",
                small_detail("LOAD · 1 / 5 / 15 MIN", function() local d = sample:get(); return if d then string.format("%.2f  /  %.2f  /  %.2f", d.load[1] or 0, d.load[2] or 0, d.load[3] or 0) else "—" end),
                small_detail("SWAP", function() local d = sample:get(); return if d then bytes(d.swap.used) .. " / " .. bytes(d.swap.total) else "—" end),
            },
        }),
        ui.column { w_full = true, gap = "$space.2",
            ui.div { w_full = true, h = 1, bg = "$border.subtle" },
            ui.row { w_full = true, gap = "$space.2",
                ui.text { state_text, grow = 1, min_w = 0, text_size = 10, color = "$text.tertiary", wrap = true },
                ui.text { "Click to refresh", text_size = 10, color = "$text.tertiary", shrink = 0 },
            },
        },
    }
end

local function bar_metric(key, title)
    return ui.row { items = "center", gap = 4,
        dot(colors[key], 3),
        ui.text { title, text_size = 10, color = "$text.tertiary" },
        ui.text { function() return percent(value_of(key)) end, w = 29, text_size = 10,
            tabular = true, color = "$text.secondary" },
    }
end

zeron.place {
    at = "#composer-toolbar",
    after = function()
        return ui.show(function() return bar_setting:get() ~= false end, ui.row {
            id = "vps-stats-meter", items = "center", shrink = 0,
            Button {
                tone = "ghost", size = "xs", label = "VPS resource usage", on_click = collect,
                tooltip = hover_card(), tooltip_placement = { side = "top", align = "start", offset = 10 },
                ui.row { items = "center", gap = "$space.3",
                    ui.row { items = "center", gap = "$space.1", color = "$text.tertiary",
                        Icon { name = "remote-server", size = 12 }, dot(status_color, 4),
                    },
                    bar_metric("cpu", "CPU"), bar_metric("memory", "RAM"), bar_metric("disk", "Disk"),
                },
            },
        })
    end,
}

local function metric(key, title, detail)
    return ui.column {
        grow = 1, min_w = 0, gap = "$space.3",
        Stat { value = function() return percent(value_of(key)) end, label = title, size = 32, line = 38 },
        meter(key, 4),
        Text { detail, style = "caption", tone = "secondary", wrap = true },
    }
end

local function detail_row(label, value)
    return Settings.Row { label = label, control = Text { value, style = "caption", tone = "secondary", tabular = true } }
end

zeron.page {
    id = "overview", title = "VPS Stats", icon = "remote-server",
    build = function()
        return ui.scroll {
            w_full = true, h_full = true,
            ui.column {
                w_full = true, items = "center", p = "$space.6",
                ui.column {
                    w_full = true, max_w = 880, gap = "$space.6",
                    ui.row {
                        w_full = true, items = "center", gap = "$space.3",
                        ui.column { grow = 1, gap = "$space.1",
                            Text { "VPS Stats", style = "title" },
                            Text { function() local d = sample:get(); return (if d then d.host else current_host) .. " · " .. state_text() end, style = "caption", tone = "secondary", wrap = true },
                        },
                        Button { "Refresh", tone = "secondary", size = "sm", busy = busy, on_click = collect },
                    },
                    ui.show(function() return sample:get() == nil end, EmptyState {
                        icon = "remote-server", title = "Waiting for VPS metrics", body = function() return state_text() .. "\nSet your SSH host in Settings → VPS Stats." end,
                    }),
                    ui.show(function() return sample:get() ~= nil end, ui.column {
                        w_full = true, gap = "$space.6",
                        ui.row {
                            w_full = true, gap = "$space.5",
                            metric("cpu", "CPU", function() local d = sample:get(); return if d then tostring(d.cores) .. " vCPU" else "" end),
                            metric("memory", "RAM", function() local d = sample:get(); return if d then bytes(d.memory.used) .. " / " .. bytes(d.memory.total) else "" end),
                            metric("disk", "Disk", function() local d = sample:get(); return if d then bytes(d.disk.available) .. " available · " .. d.disk.path else "" end),
                        },
                        ui.column {
                            gap = "$space.3", w_full = true,
                            Text { "Recent activity", style = "heading" },
                            Chart {
                                height = 210, label = "Recent CPU, memory and disk usage",
                                data = function()
                                    local x, cpu, ram, disk = {}, {}, {}, {}
                                    for _, point in history:get() do
                                        table.insert(x, os.date("%H:%M:%S", math.floor(point.at)))
                                        table.insert(cpu, point.cpu or false)
                                        table.insert(ram, point.memory or false)
                                        table.insert(disk, point.disk or false)
                                    end
                                    return { type = "line", x = x, legend = true,
                                        yaxis = { lo = 0, hi = 100, ticks = { 0, 25, 50, 75, 100 }, labels = { "0%", "25%", "50%", "75%", "100%" } },
                                        fmt = { unit = "%", decimals = 0 },
                                        series = { { name = "CPU", color = chart_color("cpu"), values = cpu }, { name = "RAM", color = chart_color("memory"), values = ram }, { name = "Disk", color = chart_color("disk"), values = disk } },
                                    }
                                end,
                            },
                        },
                        Settings.Group {
                            detail_row("Load · 1 / 5 / 15 minutes", function() local d = sample:get(); return if d then string.format("%.2f / %.2f / %.2f", d.load[1] or 0, d.load[2] or 0, d.load[3] or 0) else "—" end),
                            detail_row("Uptime", function() local d = sample:get(); return if d then uptime(d.uptime) else "—" end),
                            detail_row("Swap", function() local d = sample:get(); return if d then bytes(d.swap.used) .. " / " .. bytes(d.swap.total) else "—" end),
                            detail_row("Disk used", function() local d = sample:get(); return if d then bytes(d.disk.used) .. " / " .. bytes(d.disk.total) else "—" end),
                            detail_row("Inodes used", function() local d = sample:get(); return if d then percent(d.disk.inodePercent) else "—" end),
                            detail_row("Network download / upload", function() local d = sample:get(); return if d then bytes(d.network.down) .. "/s ↓  " .. bytes(d.network.up) .. "/s ↑" else "—" end),
                            detail_row("Network interface", function() local d = sample:get(); return if d then d.network.interface or "Not reported" else "—" end),
                            detail_row("Processes", function() local d = sample:get(); return if d then tostring(d.processes) else "—" end),
                        },
                        Text { "Read-only samples over your existing SSH connection. RAM excludes reclaimable cache; network rates are sampled on the default interface. The chart keeps the latest 120 samples while Zeron is open.", style = "caption", tone = "tertiary", wrap = true },
                    }),
                },
            },
        }
    end,
}
