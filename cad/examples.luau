-- Designs to start from: each shows a piece of the format (rounded boxes,
-- patterns, cuts, revolves), and they're what the empty state offers.

local M = {}

M.bracket = {
	name = "Mounting bracket",
	units = "mm",
	params = {
		{ id = "width", label = "Width", value = 80, min = 40, max = 160, step = 1, unit = "mm" },
		{ id = "depth", label = "Depth", value = 50, min = 30, max = 120, step = 1, unit = "mm" },
		{ id = "thickness", label = "Thickness", value = 6, min = 2, max = 20, step = 0.5, unit = "mm" },
		{ id = "hole", label = "Hole diameter", value = 6, min = 2, max = 14, step = 0.5, unit = "mm" },
		{ id = "inset", label = "Hole inset", value = 9, min = 5, max = 30, step = 0.5, unit = "mm" },
		{ id = "corner", label = "Corner radius", value = 6, min = 0, max = 20, step = 0.5, unit = "mm" },
		{ id = "flange", label = "Flange", value = true },
		{ id = "flange_h", label = "Flange height", value = 34, min = 10, max = 80, step = 1, unit = "mm" },
	},
	body = {
		{ type = "box", name = "Base plate", size = { "width", "depth", "thickness" }, radius = "corner", translate = { "-width/2", "-depth/2", 0 } },
		{ type = "box", name = "Flange", ["if"] = "flange", size = { "width", "thickness", "flange_h" }, translate = { "-width/2", "depth/2 - thickness", 0 } },
		{
			type = "group",
			name = "Mounting holes",
			mode = "cut",
			translate = { "-width/2 + inset", "-depth/2 + inset", -1 },
			["repeat"] = { count = 2, offset = { 0, "depth - 2*inset - (flange ? thickness : 0)", 0 } },
			children = {
				{ type = "cylinder", name = "Mounting hole", d = "hole", h = "thickness + 2", ["repeat"] = { count = 2, offset = { "width - 2*inset", 0, 0 } } },
			},
		},
		{
			type = "box",
			name = "Flange slot",
			["if"] = "flange",
			mode = "cut",
			size = { "width*0.45", "thickness*3", "hole" },
			radius = "hole/2 - 0.01",
			center = true,
			rotate = { 90, 0, 0 },
			translate = { 0, "depth/2 - thickness/2", "thickness + (flange_h - thickness)*0.55" },
		},
	},
}

M.planter = {
	name = "Planter",
	units = "mm",
	params = {
		{ id = "height", label = "Height", value = 70, min = 30, max = 160, step = 1, unit = "mm" },
		{ id = "top", label = "Top diameter", value = 84, min = 40, max = 180, step = 1, unit = "mm" },
		{ id = "bottom", label = "Bottom diameter", value = 58, min = 30, max = 160, step = 1, unit = "mm" },
		{ id = "wall", label = "Wall", value = 2.4, min = 1.2, max = 6, step = 0.2, unit = "mm" },
		{ id = "lip", label = "Rim lip", value = 5, min = 0, max = 15, step = 0.5, unit = "mm" },
		{ id = "drain", label = "Drain hole", value = true },
	},
	body = {
		{
			type = "revolve",
			name = "Shell",
			color = "#d9c3a5",
			-- (r, z), turned about Z: the outer wall, a lip at the rim, the
			-- inner wall back down, the floor.
			points = {
				{ 0, 0 },
				{ "bottom/2", 0 },
				{ "top/2", "height - lip" },
				{ "top/2 + lip/2", "height - lip" },
				{ "top/2 + lip/2", "height" },
				{ "top/2 - wall", "height" },
				{ "bottom/2 - wall", "wall" },
				{ 0, "wall" },
			},
		},
		{ type = "cylinder", name = "Drain hole", ["if"] = "drain", mode = "cut", d = "bottom*0.16", h = "wall*4", translate = { 0, 0, "-wall" } },
	},
}

M.knob = {
	name = "Control knob",
	units = "mm",
	params = {
		{ id = "diameter", label = "Diameter", value = 30, min = 12, max = 60, step = 0.5, unit = "mm" },
		{ id = "height", label = "Height", value = 16, min = 6, max = 40, step = 0.5, unit = "mm" },
		{ id = "grips", label = "Grips", value = 14, min = 0, max = 30, step = 1 },
		{ id = "shaft", label = "Shaft diameter", value = 6, min = 3, max = 12, step = 0.1, unit = "mm" },
	},
	vars = {
		{ id = "groove", value = "diameter * 0.12" },
	},
	body = {
		{ type = "cylinder", name = "Body", d = "diameter", h = "height", segments = 72, color = "#3a3d42" },
		{ type = "cylinder", name = "Cap", d = "diameter*0.78", h = 1.6, translate = { 0, 0, "height" }, segments = 72, color = "#e8893a" },
		{
			type = "cylinder",
			name = "Grip groove",
			["if"] = "grips > 0",
			mode = "cut",
			d = "groove",
			h = "height*3",
			segments = 16,
			translate = { "diameter/2 + groove*0.15", 0, "-height" },
			radial = { count = "max(grips, 1)" },
		},
		{ type = "cylinder", name = "Shaft bore", mode = "cut", d = "shaft", h = "height*0.75", translate = { 0, 0, -0.01 } },
		{ type = "box", name = "Shaft flat", size = { "shaft", "shaft*0.25", "height*0.75" }, translate = { "-shaft/2", "shaft*0.25", 0 } },
	},
}

M.list = {
	{ id = "bracket", label = "Mounting bracket", design = M.bracket },
	{ id = "planter", label = "Planter", design = M.planter },
	{ id = "knob", label = "Control knob", design = M.knob },
}

return M
