local zeron = require("./zeron")("headamp")
local Button = require("@ds/button")

local opened = ui.state("headamp.open", false)
local track = ui.state("headamp.track", {})
local elapsed = ui.state("headamp.elapsed", 0)
local enabled = zeron.setting("show")
local music_folders = zeron.setting("folders")
local web = ui.web("headamp-page", { profile = "headamp-local", messages = true, new_windows = false, transparent = true })
local polling = false
local artwork_installed = false
local loaded = ui.state("headamp.page-loaded", false)
local PAGE_VERSION = "1.2.1"
-- The folder library (library.luau): python3 lists the folders from Settings
-- and reads a track's bytes as it is about to play.
local HELPER = require("./library")
local TRACK_LIMIT = 5000
-- A part is small because Zeron keeps the last 32 answers it handed a plugin,
-- each with all it printed, and a plugin has 32 MB: 32 parts must fit with
-- room to spare. Several are read at once to make up for their size.
local PART_BYTES = 256 * 1024
local PARTS_AT_ONCE = 4
local CROWDED_MB = 24
local folders = {}
local scanning, scan_again = false, false
local library_rows = nil
local delivering = false
local pumping, pumped_at = false, 0

local function accept(value)
    if type(value) ~= "table" then return end
    local previous = track:peek()
    local artwork = ""
    if type(value.artworkPixels) == "string" then
        if #value.artworkPixels == 9600 and not string.find(value.artworkPixels, "[^%x]") then artwork = value.artworkPixels end
    elseif value.title == previous.title and value.artist == previous.artist then
        artwork = previous.artworkPixels or ""
    end
    local position = if type(value.position) == "number" then value.position else 0
    if elapsed:peek() ~= position then elapsed:set(position) end
    local next_track = {
        ready = value.ready == true,
        title = if type(value.title) == "string" then value.title else "",
        artist = if type(value.artist) == "string" then value.artist else "",
        artworkPixels = artwork,
        status = if type(value.status) == "string" then value.status else "STOPPED",
        duration = if type(value.duration) == "number" then value.duration else 0,
        count = if type(value.count) == "number" then value.count else 0,
        error = if type(value.error) == "string" then value.error else "",
        audio = if type(value.audio) == "string" then value.audio else "",
    }
    -- Playback emits frequent clock updates. Keep the stationary controls
    -- and artwork untouched unless their own metadata actually changes.
    for key, item in next_track do
        if previous[key] ~= item then track:set(next_track); break end
    end
end

-- Load before asking the initially empty web controller to evaluate code.
-- Its page then stays alive when the deck is folded away.
if loaded:peek() ~= PAGE_VERSION then
    web:html(require("./player")(require("./vendor")), "https://headamp.local/")
    loaded:set(PAGE_VERSION)
else
    -- Update the deck's chrome without interrupting a retained audio page.
    web:run(require("./bare"))
end

local function sync()
    if polling or not zeron.window(true).shown then return end
    polling = true
    web:eval("window.headamp ? window.headamp.snapshot() : null", function(value, _err)
        polling = false
        if type(value) == "table" then
            if value.ready and not artwork_installed then
                artwork_installed = true
                web:run(require("./artwork"))
            end
            accept(value)
        end
    end)
end

-- Zeron collects what a plugin has dropped once it is halfway to its 32 MB,
-- but only at a loop or a call of the plugin's own, and passing a part on
-- takes almost none: so loop a little after each, and the collection gets
-- its turn. Answers with what the plugin holds, in MB.
local function breathe()
    local n = 0
    for i = 1, 256 do n += i end
    return collectgarbage("count") / 1024
end

-- Hand a scan's tracks to the deck's page, again until it has taken them:
-- the page may still be starting.
local function deliver()
    local rows = library_rows
    if not rows or delivering then return end
    delivering = true
    web:eval("window.headamp&&window.headamp.library?window.headamp.library(" .. rows .. "):null", function(value, _err)
        delivering = false
        breathe()
        if type(value) == "number" and library_rows == rows then
            library_rows = nil
            sync()
        end
    end)
end

local function folder_status(badge, tone, text)
    zeron.set_status("folders", { badge = badge, tone = tone, text = text })
end

local function scan()
    if scanning then scan_again = true; return end
    local list = {}
    for part in string.gmatch(music_folders:peek() or "", "[^,\n]+") do
        local folder = string.match(part, "^%s*(.-)%s*$")
        if folder ~= "" and #list < 32 then table.insert(list, folder) end
    end
    folders = list
    if #list == 0 then
        zeron.set_status("folders", nil)
        library_rows = "[]"
        deliver()
        return
    end
    scanning = true
    local args = { "-c", HELPER, "scan", tostring(TRACK_LIMIT) }
    for _, folder in list do table.insert(args, folder) end
    local function done(result)
        scanning = false
        if scan_again then scan_again = false; scan(); return end
        local out = if result then result.stdout or "" else ""
        local cut = string.find(out, "\n", 1, true)
        local ok, found = false, nil
        if result and result.status == 0 and cut then ok, found = pcall(ui.json.decode, string.sub(out, 1, cut - 1)) end
        local rows = if cut then string.sub(out, cut + 1) else ""
        if not ok or type(found) ~= "table" or type(found.folders) ~= "table"
            or string.sub(rows, 1, 1) ~= "[" or string.sub(rows, -1) ~= "]" then
            folder_status("Needs attention", "warning",
                "Could not read the folders. Check that Python 3 is installed and that Headamp is allowed to run it in Settings → Plugins.")
            return
        end
        library_rows = rows
        deliver()
        local missing = {}
        for _, entry in found.folders do
            if type(entry) == "table" and entry.found ~= true then table.insert(missing, tostring(entry.folder)) end
        end
        local count = if type(found.tracks) == "number" then found.tracks else 0
        local badge = tostring(count) .. (if count == 1 then " track" else " tracks")
        if #missing > 0 then
            folder_status(badge, "warning", "Not found: " .. table.concat(missing, ", ") .. ". Separate folders with commas.")
        elseif found.cut == true then
            folder_status(badge, "warning", "Only the first " .. tostring(TRACK_LIMIT) .. " tracks are listed. Name fewer or smaller folders to choose which.")
        else
            folder_status(badge, "success", "Listed each time Zeron starts, subfolders too, and played from where they are. Separate folders with commas.")
        end
    end
    zeron.run("python3", args, { timeout = 60 }):after(done, function(_err) done(nil) end)
end

-- Read what the deck asks for. The page says which file and from where
-- (`want`), takes its parts in order (`feed`) and answers each with where
-- the next one starts, or with nothing once it has the file or wants another.
-- The helper refuses any file outside the folders above, and prints the
-- page's `feed` call whole, so a part is held here once and never copied.
local pump
local function relay(seq, path, offset, art)
    local label = string.format("%d", math.floor(seq))
    local call = "window.headamp&&window.headamp.feed?window.headamp.feed(" .. label .. ",{"
    local read = {}                  -- parts read ahead of the page, by where they start
    local reading, feeding, over, crowded = 0, false, false, 0
    local next_read, next_feed = offset, offset
    local fill, feed
    local function finish(unreadable)
        if over then return end
        over = true
        read = {}
        if unreadable then web:run("window.headamp&&window.headamp.failed&&window.headamp.failed(" .. label .. ")") end
        pumping = false
        pump()
    end
    feed = function()
        local out = read[next_feed]
        if over or feeding or not out then return end
        read[next_feed] = nil
        feeding = true
        web:eval(out, function(answer, _err)
            feeding = false
            pumped_at = os.time()
            if over then return end
            if type(answer) ~= "number" or answer <= next_feed then finish(false); return end
            if answer ~= next_feed + PART_BYTES then read = {}; next_read = answer end
            next_feed = answer
            fill()
            feed()
        end)
    end
    fill = function()
        -- Still crowded after a collection: wait for room, and say the file
        -- is unreadable rather than run out of memory.
        if breathe() > CROWDED_MB then
            crowded += 1
            if crowded > 20 then finish(true) else ui.after(500, function() if not over then fill() end end) end
            return
        end
        crowded = 0
        while not over and reading < PARTS_AT_ONCE and next_read < next_feed + PARTS_AT_ONCE * PART_BYTES do
            local at = next_read
            next_read += PART_BYTES
            reading += 1
            local args = { "-c", HELPER, "read", label, string.format("%d", at), tostring(PART_BYTES),
                if art and at == offset then "1" else "0", path }
            for _, folder in folders do table.insert(args, folder) end
            zeron.run("python3", args, { timeout = 30 }):after(function(result)
                reading -= 1
                pumped_at = os.time()
                if over then return end
                local out = result.stdout or ""
                if result.status ~= 0 or string.sub(out, 1, #call) ~= call or string.sub(out, -7) ~= '"):null' then finish(true); return end
                -- One the page no longer waits for (it asked to start elsewhere).
                if at >= next_feed then read[at] = out end
                feed()
            end, function(_err)
                reading -= 1
                finish(true)
            end)
        end
    end
    fill()
end
pump = function()
    if pumping then
        -- A page that went away mid-file never answers: start over.
        if os.time() - pumped_at < 45 then return end
    end
    pumping = true
    pumped_at = os.time()
    web:eval("window.headamp&&window.headamp.want?window.headamp.want():null", function(want, _err)
        if type(want) == "table" and type(want.seq) == "number" and type(want.path) == "string" then
            relay(want.seq, want.path, if type(want.offset) == "number" then math.max(0, math.floor(want.offset)) else 0, want.art == true)
        else
            pumping = false
        end
    end)
end

-- Playback is heard with the window hidden too, so the deck's requests are
-- answered then as well; only the top bar's clock waits for the window.
ui.every(1000, function()
    deliver()
    pump()
    sync()
end)
zeron.on_setting(function(id)
    if id == "folders" then scan() end
end)
scan()

local function command(action)
    web:run("window.headamp && window.headamp.command(" .. ui.json.encode(action) .. ")")
    sync()
    pump()
end
local function playing() return track:get().status == "PLAYING" end
local function time_text(seconds)
    local n = math.max(0, math.floor(seconds or 0))
    return string.format("%d:%02d", math.floor(n / 60), n % 60)
end
local function title()
    local t = track:get()
    return if t.title and t.title ~= "" then t.title else "Headamp"
end
local function subtitle()
    local t = track:get()
    if t.error and t.error ~= "" then return t.error end
    -- Playing, but the page's audio has not started: opening the deck starts it.
    if playing() and t.audio and t.audio ~= "" and t.audio ~= "running" then return "Open Headamp to hear it" end
    if (t.count or 0) == 0 then return "Add your music" end
    if t.artist and t.artist ~= "" then return t.artist end
    return if playing() then "Now playing" else "Ready when you are"
end

local function glyph(kind)
    return ui.canvas { w = 12, h = 12, aria_hidden = true, pointer_events = "none",
        draw = function(c, _w, _h)
            local color = "$text.secondary"
            if kind == "toggle" and playing() then
                c:rect(2, 2, 2.5, 8, color, 0.5)
                c:rect(7.5, 2, 2.5, 8, color, 0.5)
            else
                local path
                if kind == "previous" then
                    c:rect(1, 2, 1.5, 8, color, 0.5)
                    path = ui.path():move(10, 2):line(10, 10):line(3.5, 6):close()
                elseif kind == "next" then
                    c:rect(9.5, 2, 1.5, 8, color, 0.5)
                    path = ui.path():move(2, 2):line(2, 10):line(8.5, 6):close()
                else
                    path = ui.path():move(3, 1.5):line(3, 10.5):line(10.5, 6):close()
                end
                c:fill(path, color)
            end
        end,
    }
end

local function record_placeholder()
    return ui.canvas { w = 20, h = 20, shrink = 0, aria_hidden = true, pointer_events = "none",
        draw = function(c)
            c:rect(0, 0, 20, 20, "$surface.raised", 3)
            c:circle(10, 10, 7, "$text.tertiary")
            c:circle(10, 10, 4, "$surface.raised")
            c:circle(10, 10, 1.5, "$text.tertiary")
        end,
    }
end

local function album_cover()
    return ui.presence(function() return track:get().artworkPixels or "" end, function(pixels)
        if pixels == "" then return record_placeholder() end
        -- Build the native drawing once per cover. Adjacent equal pixels
        -- share a span; 40 pixels resolve to 20 points at Retina density.
        local spans = {}
        for y = 0, 39 do
            local x = 0
            while x < 40 do
                local first = (y * 40 + x) * 6 + 1
                local color = string.sub(pixels, first, first + 5)
                local finish = x + 1
                while finish < 40 do
                    local next_pixel = (y * 40 + finish) * 6 + 1
                    if string.sub(pixels, next_pixel, next_pixel + 5) ~= color then break end
                    finish += 1
                end
                table.insert(spans, { x = x / 2, y = y / 2, w = (finish - x) / 2, color = "#" .. color })
                x = finish
            end
        end
        return ui.div { w = 20, h = 20, shrink = 0, rounded = 3, overflow = "hidden", pointer_events = "none",
            ui.canvas { w = 20, h = 20, aria_hidden = true, pointer_events = "none",
                draw = function(c)
                    for _, span in spans do c:rect(span.x, span.y, span.w, 0.5, span.color) end
                end,
            },
        }
    end, { w = 20, h = 20, shrink = 0, pointer_events = "none" })
end

ui.command { id = "open", title = "Open Headamp", menu = "Headamp", run = function() opened:set(true) end }
ui.command { id = "play-pause", title = "Play / pause", menu = "Headamp", run = function() command("playpause") end }
ui.command { id = "next", title = "Next track", menu = "Headamp", run = function() command("next") end }
ui.command { id = "previous", title = "Previous track", menu = "Headamp", run = function() command("previous") end }
ui.command { id = "add-files", title = "Add music files…", menu = "Headamp", run = function() command("files") end }
ui.command { id = "add-folder", title = "Add music folder…", menu = "Headamp", run = function() command("folder") end }
ui.command { id = "rescan", title = "Rescan music folders", menu = "Headamp", run = function() scan() end }
ui.command { id = "close", title = "Close deck", menu = "Headamp", run = function() opened:set(false) end }

zeron.place {
    at = "#titlebar-actions-island",
    after = function()
        local trigger = ui.div {
            id = "headamp-track-display", relative = true, w = 202, h = 30, shrink = 0,
            pointer_events = "none", window_drag = false,
            ui.row { absolute = true, left = 14, top = 4, w = 174, h = 22,
                items = "center", gap = 8, pointer_events = "none",
                album_cover(),
                ui.column { w = 146, min_w = 0, gap = 0, pointer_events = "none",
                    ui.text { title, text_size = 10, line_height = 11, weight = "$font.weight.medium",
                        color = "$text.secondary", truncate = true, pointer_events = "none" },
                    ui.row { w_full = true, items = "center", gap = "$space.1", pointer_events = "none",
                        ui.text { subtitle, grow = 1, min_w = 0, text_size = 9, line_height = 10,
                            color = "$text.tertiary", truncate = true, pointer_events = "none" },
                        ui.text { function() return if (track:get().duration or 0) > 0 then time_text(elapsed:get()) else "" end,
                            text_size = 9, line_height = 10, tabular = true, color = "$text.tertiary", pointer_events = "none" },
                    },
                },
            },
            -- One stationary click/hover plane, independent of cover changes
            -- and the running clock. No popup is attached to this surface.
            Button {
                id = "headamp-open", absolute = true, left = 0, top = 0, w = 202, h = 30,
                tone = "ghost", size = "xs", shrink = 0, window_drag = false,
                label = function() return if opened:get() then "Close Headamp" else "Open Headamp" end,
                on_click = function() opened:set(not opened:peek()) end,
                ui.div { w = 0, h = 0, aria_hidden = true, pointer_events = "none" },
            },
        }
        return ui.row {
            id = "headamp-player", absolute = true, right = 120, top = 6, w = 280, h = 30,
            items = "center", shrink = 0, window_drag = false,
            pointer_events = function() return if enabled:get() ~= false then "auto" else "none" end,
            ui.show(function() return enabled:get() ~= false end, ui.row { h = 30, items = "center", gap = 2,
            trigger,
            Button { tone = "ghost", size = "xs", icon = true, label = "Previous track", shrink = 0, window_drag = false,
                disabled = function() return (track:get().count or 0) == 0 end,
                on_click = function() command("previous") end, glyph("previous") },
            Button { tone = "ghost", size = "xs", icon = true, shrink = 0, window_drag = false, label = function() return if playing() then "Pause music" else "Play music" end,
                disabled = function() return (track:get().count or 0) == 0 end,
                on_click = function() command("playpause") end, glyph("toggle") },
            Button { tone = "ghost", size = "xs", icon = true, label = "Next track", shrink = 0, window_drag = false,
                disabled = function() return (track:get().count or 0) == 0 end,
                on_click = function() command("next") end, glyph("next") },
            }),
        }
    end,
}

-- Native web views belong to the main window. An in-window overlay keeps
-- the deck interactive without moving its WebKit surface into a menu popup.
zeron.place {
    at = "#titlebar",
    after = function()
        return ui.div {
            id = "headamp-overlay", absolute = true, left = 0, right = 0, top = 0, bottom = 0,
            pointer_events = "none",
            ui.div { absolute = true, left = 0, right = 0, top = 38, bottom = 0,
                pointer_events = function() return if opened:get() then "auto" else "none" end,
                bg = "#00000000", on_click = function() opened:set(false) end },
            -- The page stays in the window when the deck is folded, a point in
            -- size: WebKit starts no sound in a page that is in no window, so a
            -- track started from the top bar played silently until the deck had
            -- been opened and clicked.
            ui.column { id = "headamp-deck", absolute = true, right = 120, top = 48,
                w = function() return if opened:get() then 550 else 1 end,
                h = function() return if opened:get() then 261 else 1 end,
                pointer_events = function() return if opened:get() then "auto" else "none" end,
                ui.webview { id = "headamp-webview", label = "Headamp music player", web = web,
                    w = function() return if opened:get() then 550 else 1 end,
                    h = function() return if opened:get() then 261 else 1 end,
                    pointer_events = function() return if opened:get() then "auto" else "none" end,
                    on_message = function(value, _origin, main_frame)
                        if not main_frame or type(value) ~= "table" then return end
                        if value.kind == "headamp.state" then accept(value)
                        elseif value.kind == "headamp.want" then pump()
                        elseif value.kind == "headamp.close" then opened:set(false) end
                    end,
                },
            },
        }
    end,
}
