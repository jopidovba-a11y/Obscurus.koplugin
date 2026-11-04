-- Window in the style of the reference art: thick black frame, white
-- title strip with an "x", and a dithered drop shadow.
-- All coordinates are logical dots.
local Blitbuffer = require("ffi/blitbuffer")
local Dither = require("dither")

local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local Window = {}
Window.__index = Window

Window.FRAME = 2      -- outer black frame thickness
Window.TITLE_H = 9    -- white title strip height
Window.PAD = 3        -- white gap between the frame and the content
Window.SHADOW = 3
-- Total vertical space taken by frame + title strip + padding
Window.CHROME = 2 * Window.FRAME + Window.TITLE_H + 2 * Window.PAD

function Window.new(x, y, w, h, content_bg, scale, x_right)
    local self = setmetatable({}, Window)
    local F = Window.FRAME
    self.x, self.y, self.w, self.h = x, y, w, h
    self.s = scale
    self.bg = content_bg
    self.x_right = x_right
    -- Content area (inside the frame, below the title strip)
    self.cx, self.cy = x + F + Window.PAD, y + F + Window.TITLE_H + Window.PAD
    self.cw, self.ch = w - 2 * (F + Window.PAD), h - Window.CHROME
    -- Generous hit area for the "x" (left side, or right side for popups)
    local hit_x = x_right and (x + w - 16) or x
    self.close_rect = { x = hit_x, y = y, w = 16, h = F + Window.TITLE_H + 1 }
    return self
end

function Window:paint(bb, ox, oy)
    local s, F = self.s, Window.FRAME
    local function rect(x, y, w, h, c)
        bb:paintRect(ox + x * s, oy + y * s, w * s, h * s, c)
    end

    -- Dithered shadow
    Dither.fill(bb, ox + (self.x + Window.SHADOW) * s, oy + (self.y + Window.SHADOW) * s,
        self.w * s, self.h * s, 0.5, s)

    -- Black frame, white inside
    rect(self.x, self.y, self.w, self.h, BLACK)
    rect(self.x + F, self.y + F, self.w - 2 * F, self.h - 2 * F, WHITE)

    -- The "x" (5 rows tall, 2 dots thick)
        local gy = self.y + F + 2
    if self.x_right then
        -- "x" close button (popups)
        local gx = self.x + self.w - F - 9
        for i = 0, 4 do
            rect(gx + i, gy + i, 2, 1, BLACK)
            rect(gx + 4 - i, gy + i, 2, 1, BLACK)
        end
    else
        -- Circle (dashboard windows), so it is not mistaken for a close button
        local x0, y0 = self.x + F + 3, self.y + F + 1
        rect(x0 + 2, y0, 3, 1, BLACK)
        rect(x0 + 1, y0 + 1, 1, 1, BLACK)
        rect(x0 + 5, y0 + 1, 1, 1, BLACK)
        for r = 2, 4 do
            rect(x0, y0 + r, 1, 1, BLACK)
            rect(x0 + 6, y0 + r, 1, 1, BLACK)
        end
        rect(x0 + 1, y0 + 5, 1, 1, BLACK)
        rect(x0 + 5, y0 + 5, 1, 1, BLACK)
        rect(x0 + 2, y0 + 6, 3, 1, BLACK)
    end
    
    -- Content background (black for the skull window)
    if self.bg == BLACK then
        rect(self.cx, self.cy, self.cw, self.ch, BLACK)
    end
end
return Window