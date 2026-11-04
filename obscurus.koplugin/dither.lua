-- Ordered (Bayer 4x4) dithering. Every logical dot is drawn as a
-- scale x scale block of real pixels, so the pattern stays crisp.
local Blitbuffer = require("ffi/blitbuffer")

local Dither = {}

local BAYER = {
     0,  8,  2, 10,
    12,  4, 14,  6,
     3, 11,  1,  9,
    15,  7, 13,  5,
}

Dither.BAYER = BAYER

local tiles = {}

-- The 4x4 Bayer matrix is repeated inside a larger tile (TILE_DOTS x TILE_DOTS)
-- so that filling large areas needs far fewer blitFrom() calls. The pattern
-- is exactly the same as a plain 4x4 tile; only the tiling is different.
local TILE_DOTS = 16

function Dither.tile(level, scale)
    local n = math.floor(math.max(0, math.min(1, level)) * 16 + 0.5)
    local key = n .. ":" .. scale
    if tiles[key] then return tiles[key] end
    local size = TILE_DOTS * scale
    local t = Blitbuffer.new(size, size, Blitbuffer.TYPE_BB8)
    t:fill(Blitbuffer.COLOR_BLACK)
    for j = 0, TILE_DOTS - 1 do
        for i = 0, TILE_DOTS - 1 do
            if BAYER[(j % 4) * 4 + (i % 4) + 1] < n then
                t:paintRect(i * scale, j * scale, scale, scale, Blitbuffer.COLOR_WHITE)
            end
        end
    end
    tiles[key] = t
    return t
end

-- Fill a rectangle of the target buffer with a gray level.
function Dither.fill(bb, x, y, w, h, level, scale)
    local t = Dither.tile(level, scale)
    local size = t:getWidth()
    for dy = 0, h - 1, size do
        local bh = math.min(size, h - dy)
        for dx = 0, w - 1, size do
            bb:blitFrom(t, x + dx, y + dy, 0, 0, math.min(size, w - dx), bh)
        end
    end
end

function Dither.free()
    for _, t in pairs(tiles) do t:free() end
    tiles = {}
end

return Dither