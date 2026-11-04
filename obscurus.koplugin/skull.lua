-- Loads the 1-bit skull PNG and scales it by an integer factor
-- (nearest neighbor), so the dots stay sharp on any screen.
local Blitbuffer = require("ffi/blitbuffer")
local RenderImage = require("ui/renderimage")

local Skull = {}

function Skull.load(path, scale)
    local src = RenderImage:renderImageFile(path, false)
    if not src then return nil end
    local sw, sh = src:getWidth(), src:getHeight()
    local out = Blitbuffer.new(sw * scale, sh * scale, Blitbuffer.TYPE_BB8)
    out:fill(Blitbuffer.COLOR_BLACK)
    for y = 0, sh - 1 do
        local run_start
        for x = 0, sw do
            local white = x < sw and src:getPixel(x, y):getColor8().a > 127
            if white and not run_start then
                run_start = x
            elseif not white and run_start then
                out:paintRect(run_start * scale, y * scale,
                    (x - run_start) * scale, scale, Blitbuffer.COLOR_WHITE)
                run_start = nil
            end
        end
    end
    src:free()
    return out
end

return Skull