-- Original 14-by-16 pixel artwork. Compile equal-colour runs once, so
-- each animation frame paints a few dozen crisp GPU rectangles.
local M = { width = 14, height = 16 }
M.palette = {
    h = "$palette.red.500",
    k = "$palette.amber.950",
    s = "$palette.orange.200",
    t = "$palette.red.400",
    p = "$palette.teal.500",
    b = "$palette.amber.700",
    y = "$palette.yellow.200",
}

local head = {
    "....hhhhh.....",
    "...hhhhhhhh...",
    "...kksssks....",
    "..ksssssks....",
    "..kssssssss...",
    "...ksssss.....",
    "....ssss......",
    "...tttttt.....",
}

local poses = {
    {
        "..ttpttptt....", "..ttpyyptt....",
        "..ssppppss....", "...pppppp.....",
        "...pp..pp.....", "..pp....pp....", "..bb....bb....", ".bbb....bbb...",
    },
    {
        "...tpttpt.....", "...tpyypt.....",
        "...spppps.....", "....pppp......",
        "....pppp......", "....pppp......", "....bbbb......", "....bbbbb.....",
    },
    {
        "..ttpttptt....", "..ttpyyptt....",
        "...sppppsss...", "...pppppp.....",
        "...pp..pp.....", "....pp..pp....", "....bb..bb....", "...bbb..bbb...",
    },
    {
        "...tpttpt.....", "...tpyypt.....",
        "...spppps.....", "....pppp......",
        "...pppp.......", "...pppp.......", "...bbbb.......", "...bbbbb......",
    },
}

M.frames = {}
for _, pose in poses do
    local rows = table.clone(head)
    for _, row in pose do table.insert(rows, row) end
    assert(#rows == M.height)
    local spans = {}
    for y, row in rows do
        assert(#row == M.width, "Sprite rows must be fourteen pixels wide")
        local x = 1
        while x <= #row do
            local color = string.sub(row, x, x)
            local edge = x + 1
            while edge <= #row and string.sub(row, edge, edge) == color do edge += 1 end
            if color ~= "." then
                assert(M.palette[color], "Unknown sprite colour")
                table.insert(spans, { x = x - 1, y = y - 1, w = edge - x, color = color })
            end
            x = edge
        end
    end
    table.insert(M.frames, spans)
end
return M
