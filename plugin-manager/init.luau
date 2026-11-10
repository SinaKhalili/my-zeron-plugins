local zeron = require("./zeron")("plugin-manager")
local EmptyState = require("@ds/empty_state")

-- Plugin Manager: a "Plugins" row in the sidebar that opens Settings →
-- Plugins in one click.
--
-- A sidebar row is a page of ours ("pages.add"), so a click opens our page
-- and we send the window on to Settings ("navigate"). Settings' close is a
-- step back in history, which lands on our page again; sending it to
-- Settings then would trap you there. So coming back from Settings, we
-- return you to the chat you clicked from instead.

local PAGE = "plugin-manager"

-- Where you were before our page (a chat, or a new chat), to return to.
local before: any = { name = "home" }
local last: any = nil

local function ours(r: any): boolean
	return r and r.name == "plugin" and r.page == PAGE
end

local function open_plugins()
	zeron.open({ settings = "plugins" })
end

local function go_back()
	if before.name == "session" and type(before.session) == "string" then
		zeron.open({ session = before.session })
	else
		zeron.open("home")
	end
end

local route = ui.shared("zeron.route", { name = "home" } :: any)
ui.effect(function()
	local now = route:get()
	local was = last
	last = now
	if not ours(now) then
		if now.name == "session" or now.name == "home" then
			before = { name = now.name, session = now.session }
		end
		return
	end
	-- (After this effect: navigating from inside it would re-enter it.)
	local back = was ~= nil and was.name == "settings"
	ui.after(0, function()
		if not ours(route:peek()) then
			return
		end
		if back then
			go_back()
		else
			open_plugins()
		end
	end)
end)

zeron.page {
	id = PAGE,
	title = zeron.t("page.title"),
	icon = "widget",
	-- (Shown only for the moment before Settings opens, or if it can't.)
	build = function(): Node
		return ui.column {
			w_full = true,
			h_full = true,
			EmptyState {
				icon = "widget",
				fill = true,
				title = zeron.t("page.title"),
				body = zeron.t("page.body"),
				action = { label = zeron.t("page.open"), icon = "widget", on_click = open_plugins },
			},
		}
	end,
}
