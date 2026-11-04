-- Statistics window: overview numbers, 7-day and hour-of-day histograms and
-- an activity heatmap, all inside one closable window drawn over the
-- dashboard (same look as the rest of the plugin).
local Blitbuffer = require("ffi/blitbuffer")
local Data = require("statsdata")
local Books = require("books")
local Device = require("device")
local Dither = require("dither")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Window = require("window")

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min

-- First and last pixel rows of a text widget that really contain ink.
local function inkRows(tw)
    local size = tw:getSize()
    local tmp = Blitbuffer.new(size.w, size.h)
    tmp:fill(WHITE)
    tw:paintTo(tmp, 0, 0)
    local top, bottom
    for y = 0, size.h - 1 do
        for x = 0, size.w - 1 do
            if tmp:getPixel(x, y):getColor8().a < 128 then
                top = top or y
                bottom = y
                break
            end
        end
    end
    tmp:free()
    return top or 0, bottom or size.h - 1
end

local SIDE = 8          -- gap between the window and the screen edges
local SECTION_GAP = 6   -- gap between sections inside the window

local MONO_FONTS = {
    "DroidSansMono.ttf", "droid/DroidSansMono.ttf",
    "NotoSansMono-Regular.ttf", "DejaVuSansMono.ttf", "FreeMono.ttf",
}
local function monoFace(size)
    for _, name in ipairs(MONO_FONTS) do
        local ok, face = pcall(Font.getFace, Font, name, size)
        if ok and face then return face end
    end
    return Font:getFace("cfont", size)
end

local function fmtDur(sec)
    local m = floor((sec or 0) / 60)
    if m < 60 then return m .. "m" end
    local h = floor(m / 60)
    if h >= 100 then return h .. "h" end
    return string.format("%dh%02d", h, m % 60)
end

local function fmtCount(n)
    n = n or 0
    if n >= 10000 then return string.format("%.1fk", n / 1000) end
    return tostring(floor(n))
end

-- Prerendered heatmap cells. Level 0 = empty, 1..3 = dithered, 4 = full.
-- Rendering once per (level, scale) and blitting is much faster on e-ink
-- than drawing each cell rectangle by rectangle.
local cell_tiles = {}
local CELL_FILLS = { [1] = 0.75, [2] = 0.5, [3] = 0.25 }

local function cellTile(lvl, scale)
    local key = lvl .. ":" .. scale
    local tile = cell_tiles[key]
    if tile then return tile end
    local size = 6 * scale
    tile = Blitbuffer.new(size, size, Blitbuffer.TYPE_BB8)
    tile:fill(BLACK)
    tile:paintRect(scale, scale, 4 * scale, 4 * scale, WHITE)
    local fill = CELL_FILLS[lvl]
    if fill then
        Dither.fill(tile, scale, scale, 4 * scale, 4 * scale, fill, scale)
    elseif lvl >= 4 then
        tile:paintRect(scale, scale, 4 * scale, 4 * scale, BLACK)
    end
    cell_tiles[key] = tile
    return tile
end

local Stats = InputContainer:extend{
    name = "dotdash_stats",
    scale = 1, ox = 0, oy = 0, canvas_w = 0, canvas_h = 0,
    reader_ui = nil,
}

function Stats:init()
    local s = self.scale
    self.s = s
    local W, H = Screen:getWidth(), Screen:getHeight()
    -- The SQL aggregates are loaded immediately; the potentially expensive
    -- per-book finished count is filled in small batches after first paint.
    self.data = Data.load(true)
    self:layout()
    if self.data.finished == nil then
        self.finished_files = Books.history()
        self.finished_index = 1
        self.finished_count = 0
        self.finished_task = function() self:loadFinishedBatch() end
        UIManager:scheduleIn(0.05, self.finished_task)
    end

    -- The widget only draws the window, but it swallows every touch so the
    -- dashboard underneath does not react while the window is open.
    local full = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = full } },
        Swipe = { GestureRange:new{ ges = "swipe", range = full } },
        Hold = { GestureRange:new{ ges = "hold", range = full } },
    }
end

-- One window sized to its content, centered; sections are stacked inside.
function Stats:layout()
    local s = self.s
    local chrome = Window.CHROME
    local Wl, Hl = self.canvas_w, self.canvas_h
    local sec_h = { overview = 64, days = 92, hours = 74, heat = 76 }
    local base = sec_h.overview + sec_h.days + sec_h.hours + sec_h.heat
        + 3 * SECTION_GAP + 4
    -- Taller screens get a bit more room for the charts
    local avail = Hl - 2 * 16 - chrome
    local extra = max(0, min(40, avail - base))
    local more_days = floor(extra * 0.6)
    sec_h.days = sec_h.days + more_days
    sec_h.hours = sec_h.hours + (extra - more_days)

    local w = Wl - 2 * SIDE
    local h = min(base + extra + chrome, Hl - 8)
    local win = Window.new(floor((Wl - w) / 2), floor((Hl - h) / 2), w, h, WHITE, s, true)
    self.win = win

    -- Section rectangles (same field names as a Window's content area)
    self.secs = {}
    local y = win.cy + 2
    for _, id in ipairs({ "overview", "days", "hours", "heat" }) do
        self.secs[id] = { cx = win.cx, cy = y, cw = win.cw, ch = sec_h[id] }
        y = y + sec_h[id] + SECTION_GAP
    end

    -- Screen regions: window with shadow, and the "x" hit area
    self.region = Geom:new{
        x = max(0, self.ox + win.x * s), y = max(0, self.oy + win.y * s),
        w = (win.w + Window.SHADOW) * s, h = (win.h + Window.SHADOW) * s,
    }
    self.dimen = self.region
    local cr = win.close_rect
    self.close_px = Geom:new{
        x = self.ox + cr.x * s, y = self.oy + cr.y * s, w = cr.w * s, h = cr.h * s,
    }
end

-- ---------------------------------------------------------------- helpers

function Stats:face(mul) return monoFace(floor(mul * self.s)) end

function Stats:mk(text, mul, max_w)
    return TextWidget:new{
        text = text, face = self:face(mul),
        max_width = max_w and (max_w * self.s) or nil,
    }
end

-- Largest text between hi and lo (dots of font size) that fits max_w x max_h px.
function Stats:fit(text, max_w, max_h, hi, lo)
    local step = (hi - lo > 10) and 2 or 1
    for mul = hi, lo, -step do
        local tw = TextWidget:new{ text = text, face = self:face(mul) }
        local size = tw:getSize()
        if size.w <= max_w and size.h <= max_h then return tw end
        tw:free()
    end
    return TextWidget:new{ text = text, face = self:face(lo), max_width = max_w }
end

-- Paints and frees a text widget at (x, y) dots; returns its height in dots.
function Stats:put(bb, ox, oy, tw, x, y, align)
    local s = self.s
    local size = tw:getSize()
    local px = ox + x * s
    if align == "center" then
        px = px - floor(size.w / 2)
    elseif align == "right" then
        px = px - size.w
    end
    tw:paintTo(bb, px, oy + y * s)
    tw:free()
    return ceil(size.h / s)
end

function Stats:rect(bb, ox, oy, x, y, w, h, c)
    local s = self.s
    bb:paintRect(ox + x * s, oy + y * s, w * s, h * s, c)
end

-- Histogram bar: dithered with an outline, or solid black to highlight it.
function Stats:bar(bb, ox, oy, x, y, w, h, solid)
    if h <= 0 then return end
    local s = self.s
    if solid or h <= 2 or w <= 2 then
        self:rect(bb, ox, oy, x, y, w, h, BLACK)
        return
    end
    Dither.fill(bb, ox + x * s, oy + y * s, w * s, h * s, 0.5, s)
    self:rect(bb, ox, oy, x, y, w, 1, BLACK)
    self:rect(bb, ox, oy, x, y + h - 1, w, 1, BLACK)
    self:rect(bb, ox, oy, x, y, 1, h, BLACK)
    self:rect(bb, ox, oy, x + w - 1, y, 1, h, BLACK)
end

-- Heatmap cell, 6x6 dots, level 0 (empty) to 4 (black). The pattern is
-- prerendered once and blitted, so each cell costs a single call.
function Stats:cell(bb, ox, oy, x, y, lvl)
    local s = self.s
    bb:blitFrom(cellTile(lvl, s), ox + x * s, oy + y * s, 0, 0, 6 * s, 6 * s)
end

-- Section title with a dotted rule well below the text; returns where the
-- chart can start.
function Stats:label(bb, ox, oy, win, left, right)
    local s = self.s
    self:put(bb, ox, oy, self:mk(left, 5), win.cx + 2, win.cy + 1, "left")
    if right then
        self:put(bb, ox, oy, self:mk(right, 5), win.cx + win.cw - 2, win.cy + 1, "right")
    end
    Dither.fill(bb, ox + (win.cx + 2) * s, oy + (win.cy + 12) * s, (win.cw - 4) * s, s, 0.5, s)
    return win.cy + 15
end

function Stats:message(bb, ox, oy, win, y_top)
    local cx = win.cx + floor(win.cw / 2)
    local mid = y_top + floor((win.cy + win.ch - y_top) / 2)
    self:put(bb, ox, oy, self:mk("NO STATISTICS DATA", 6), cx, mid - 8, "center")
    self:put(bb, ox, oy, self:mk("enable Reading statistics", 5), cx, mid + 2, "center")
end

-- ---------------------------------------------------------------- sections

function Stats:paintOverview(bb, ox, oy, win)
    local s, d = self.s, self.data
    local ns = d.no_stats
    local dash = "--"
    local cells = {
        { ns and dash or fmtDur(d.today_secs), "TODAY" },
        { ns and dash or fmtCount(d.today_pages), "PAGES TODAY" },
        { ns and dash or fmtDur(d.avg7), "7-DAY AVG" },
        { ns and dash or (d.streak .. "d"), "STREAK" },
        { ns and dash or fmtDur(d.total_secs), "TOTAL TIME" },
        { ns and dash or fmtCount(d.total_pages), "TOTAL PAGES" },
        { tostring(d.history_count), "IN HISTORY" },
        { d.finished ~= nil and tostring(d.finished) or "...", "FINISHED" },
    }
    local x0, y0 = win.cx + 2, win.cy + 2
    local w, h = win.cw - 4, win.ch - 4
    local cw, ch = floor(w / 4), floor(h / 2)

    for i, c in ipairs(cells) do
        local col, row = (i - 1) % 4, floor((i - 1) / 4)
        local cx = x0 + col * cw + floor(cw / 2)
        -- The value is capped to half of the cell so nothing touches the rules
        local value = self:fit(c[1], (cw - 6) * s, floor(ch * 0.5 * s), 12, 5)
        local label = self:mk(c[2], 4.5)
        local vh = ceil(value:getSize().h / s)
        local lh = ceil(label:getSize().h / s)
        local top = y0 + row * ch + floor((ch - (vh + 1 + lh)) / 2)
        self:put(bb, ox, oy, value, cx, top, "center")
        self:put(bb, ox, oy, label, cx, top + vh + 1, "center")
    end
    -- Dotted separators
    for c = 1, 3 do
        Dither.fill(bb, ox + (x0 + c * cw) * s, oy + y0 * s, s, h * s, 0.5, s)
    end
    Dither.fill(bb, ox + x0 * s, oy + (y0 + ch) * s, w * s, s, 0.5, s)

    -- White numbers on black
    bb:invertRect(ox + win.cx * s, oy + win.cy * s, win.cw * s, win.ch * s)
end

function Stats:paintDays(bb, ox, oy, win)
    local s, d = self.s, self.data
    local y_top = self:label(bb, ox, oy, win, "LAST 7 DAYS",
        (not d.no_stats) and ("TOTAL " .. fmtDur(d.week_secs)) or nil)
    if d.no_stats then
        self:message(bb, ox, oy, win, y_top)
        return
    end
    local series, maxv = {}, 1800
    for i = 6, 0, -1 do
        local t = d.noon - i * 86400
        local x = d.days[os.date("%Y-%m-%d", t)]
        local secs = x and x.secs or 0
        maxv = max(maxv, secs)
        series[#series + 1] = { secs = secs, name = os.date("%a", t):sub(1, 3), today = i == 0 }
    end

    local x0, w = win.cx + 3, win.cw - 6
    local n, gap = 7, 4
    local bw = floor((w - gap * (n - 1)) / n)
    local bx0 = x0 + floor((w - (n * bw + (n - 1) * gap)) / 2)
    local base = win.cy + win.ch - 2 - 9
    local max_h = max(4, base - (y_top + 9))
    self:rect(bb, ox, oy, x0, base, w, 1, BLACK)
    for i, v in ipairs(series) do
        local bx = bx0 + (i - 1) * (bw + gap)
        local h = floor(v.secs / maxv * max_h + 0.5)
        if v.secs > 0 then h = max(h, 2) end
        self:bar(bb, ox, oy, bx, base - h, bw, h, v.today)
        local cx = bx + floor(bw / 2)
        if v.secs > 0 then
            local tw = self:fit(fmtDur(v.secs), (bw + gap) * s, 8 * s, 6, 3)
            self:put(bb, ox, oy, tw, cx, base - h - 9, "center")
        end
        self:put(bb, ox, oy, self:mk(v.name, 5), cx, base + 2, "center")
    end
end

function Stats:paintHours(bb, ox, oy, win)
    local d = self.data
    local peak_h, peak_v = nil, 0
    for h = 0, 23 do
        if d.hours[h] > peak_v then peak_h, peak_v = h, d.hours[h] end
    end
    local y_top = self:label(bb, ox, oy, win, "HOURS - LAST 30 DAYS",
        peak_h and string.format("PEAK %02d:00", peak_h) or nil)
    if d.no_stats then
        self:message(bb, ox, oy, win, y_top)
        return
    end
    local x0, w = win.cx + 3, win.cw - 6
    local gap = 1
    local bw = max(1, floor((w - gap * 23) / 24))
    local bx0 = x0 + floor((w - (24 * bw + 23 * gap)) / 2)
    local base = win.cy + win.ch - 2 - 9
    local max_h = max(4, base - (y_top + 2))
    self:rect(bb, ox, oy, x0, base, w, 1, BLACK)
    for hr = 0, 23 do
        local v = d.hours[hr]
        local h = floor(v / max(peak_v, 1) * max_h + 0.5)
        if v > 0 then h = max(h, 2) end
        local bx = bx0 + hr * (bw + gap)
        self:bar(bb, ox, oy, bx, base - h, bw, h, hr == peak_h)
        if hr % 6 == 0 then
            self:put(bb, ox, oy, self:mk(tostring(hr), 4.5), bx + floor(bw / 2), base + 2, "center")
        end
    end
    -- "24" label at the right edge of the last bar (end of hour 23)
    local bx_end = bx0 + 24 * bw + 23 * gap
    self:put(bb, ox, oy, self:mk("24", 4.5), bx_end, base + 2, "right")
end

-- Calendar-style grid filling the whole width: one column per week, one row
-- per weekday (Monday on top). The last column is the current week and is
-- always drawn complete; days that have not happened yet are empty squares.
function Stats:paintHeat(bb, ox, oy, win)
    local s, d = self.s, self.data
    local y_top = self:label(bb, ox, oy, win, "ACTIVITY", nil)

    -- 12 dots at the left for the weekday letters, 7 dots of margin at the right
    local weeks = min(85, floor((win.cw - 19 + 1) / 7))
    local gx0 = win.cx + 12 + floor((win.cw - 19 - (weeks * 7 - 1)) / 2)
    local right = gx0 + weeks * 7 - 1                     -- right edge of the grid
    local gy0 = y_top + 12   -- room for the month names above the grid

    -- Legend: empty to full, aligned with the right edge of the grid
    local lx = right - 5 * 7 + 2
    for lvl = 0, 4 do self:cell(bb, ox, oy, lx + lvl * 7, win.cy + 2, lvl) end

    -- Weekday initials, one per row (Monday on top). The ink of each letter
    -- is measured and centered on its row of squares, so it does not depend
    -- on the font metrics.
    for r, letter in ipairs({ "M", "T", "W", "T", "F", "S", "S" }) do
        local tw = self:mk(letter, 3.2)
        local top, bottom = inkRows(tw)
        local row_center = oy + (gy0 + (r - 1) * 7) * s + 3 * s   -- middle of the 6-dot square
        local py = floor(row_center - (top + bottom + 1) / 2)
        tw:paintTo(bb, ox + (win.cx + 3) * s, py)
        tw:free()
    end

    local now = os.date("*t", d.noon)
    local row_today = (now.wday + 5) % 7                  -- Monday = 0
    local first = d.noon - row_today * 86400 - (weeks - 1) * 7 * 86400
    local today_idx = (weeks - 1) * 7 + row_today
    local last_end = -100

    for c = 0, weeks - 1 do
        local month_t = nil          -- a day 1 inside this column, if any
        for r = 0, 6 do
            local idx = c * 7 + r
            local t = first + idx * 86400
            local lvl = 0
            if idx <= today_idx then
                local day = d.days[os.date("%Y-%m-%d", t)]
                local minutes = day and day.secs / 60 or 0
                if minutes > 0 then lvl = 1 end
                if minutes >= 10 then lvl = 2 end
                if minutes >= 30 then lvl = 3 end
                if minutes >= 60 then lvl = 4 end
            end
            self:cell(bb, ox, oy, gx0 + c * 7, gy0 + r * 7, lvl)
            if os.date("%d", t) == "01" then month_t = t end
        end
        -- Month name over the column where the month starts. Skipped if it
        -- does not fit, touches the previous name, or is last year's current
        -- month (it would show the same name at both ends).
        if month_t and not (tonumber(os.date("%m", month_t)) == now.month
                            and d.noon - month_t > 200 * 86400) then
            local tw = self:mk(os.date("%b", month_t), 4.5)
            local lw = ceil(tw:getSize().w / s)
            local x = gx0 + c * 7
            if x + lw <= right + 6 and x >= last_end + 4 then
                self:put(bb, ox, oy, tw, x, y_top, "left")
                last_end = x + lw
            else
                tw:free()
            end
        end
    end
end

-- ------------------------------------------------------------------ widget

function Stats:paintTo(bb, x, y)
    -- Defensive fallback if a backend repaints before delivering SetDimensions.
    local landscape = Screen:getWidth() > Screen:getHeight()
    if landscape ~= self.suspended then
        self:onSetDimensions()
    end
    if self.suspended then return end
    local ox, oy = x + self.ox, y + self.oy
    self.win:paint(bb, ox, oy)
    self:paintOverview(bb, ox, oy, self.secs.overview)
    self:paintDays(bb, ox, oy, self.secs.days)
    self:paintHours(bb, ox, oy, self.secs.hours)
    self:paintHeat(bb, ox, oy, self.secs.heat)
end

function Stats:loadFinishedBatch()
    if self.closed or self.suspended then return end
    local added, next_index = Data.countFinishedBatch(
        self.finished_files, self.finished_index, 8)
    self.finished_count = self.finished_count + added
    self.finished_index = next_index
    if self.finished_index <= math.min(#self.finished_files, 300) then
        UIManager:scheduleIn(0.03, self.finished_task)
    else
        self.data.finished = self.finished_count
        Data.setFinishedCount(self.finished_count)
        self.finished_task = nil
        UIManager:setDirty(self, "ui", self.region)
    end
end

function Stats:onShow()
    UIManager:setDirty(self, function() return "ui", self.region end)
end

function Stats:showMenu()
    local menu = self.reader_ui and self.reader_ui.menu
    if menu and menu.onShowMenu then
        pcall(menu.onShowMenu, menu)
    end
end

-- In landscape, use the current screen geometry directly instead of relying
-- on the portrait GestureRanges captured when this window was created.
function Stats:onGesture(ges)
    local landscape = Screen:getWidth() > Screen:getHeight()
    if landscape ~= self.suspended then
        self:onSetDimensions()
    end
    if self.suspended then
        if not UIManager._input_gestures_disabled then
            local H = Screen:getHeight()
            if (ges.ges == "tap" and ges.pos.y < H * 0.1)
                or (ges.ges == "swipe" and ges.direction == "south"
                    and ges.pos.y < H * 0.15) then
                self:showMenu()
                return true
            end
        end
        -- Nothing in the portrait statistics window is interactive in
        -- landscape; let KOReader continue handling the remaining gestures.
        return false
    end
    return InputContainer.onGesture(self, ges)
end

function Stats:onTap(_, ges)
    local r, pos = self.close_px, ges.pos
    if self.suspended then
        if pos.y < Screen:getHeight() * 0.1 then
            self:showMenu()
            return true
        end
        return false
    end
    if pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h then
        UIManager:close(self)
    elseif pos.y < Screen:getHeight() * 0.1 then
        -- Tap near the top edge: open the main menu
        self:showMenu()
    end
    return true
end

function Stats:onSwipe(_, ges)
    -- Swipe down from the top edge: open the main menu, including while the
    -- statistics window is invisible in landscape.
    if ges.direction == "south" and ges.pos.y < Screen:getHeight() * 0.15 then
        self:showMenu()
        return true
    end
    return not self.suspended
end
function Stats:onHold() return not self.suspended end

function Stats:onSetDimensions()
    local landscape = Screen:getWidth() > Screen:getHeight()
    if landscape == self.suspended then return end
    self.suspended = landscape
    -- Keep this widget as the input target; paintTo() skips its portrait UI.
    self.invisible = nil
    if landscape then
        if self.finished_task then UIManager:unschedule(self.finished_task) end
    elseif self.finished_task then
        UIManager:scheduleIn(0.05, self.finished_task)
    end
    -- Dashboard handles the full-stack repaint so lower widgets are restored.
end

function Stats:onCloseWidget()
    self.closed = true
    if self.finished_task then UIManager:unschedule(self.finished_task) end
    -- Repaint what was under the window (the dashboard)
    UIManager:setDirty(nil, function() return "ui", self.region end)
end

return Stats