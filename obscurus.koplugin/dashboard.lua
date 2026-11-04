local Blitbuffer = require("ffi/blitbuffer")
local Books = require("books")
local Covers = require("covers")
local Device = require("device")
local Dither = require("dither")
local Explorer = require("explorer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local last_library = nil   -- survives between Dashboard instances
local last_offset = 0      -- library page, survives between Dashboard instances
local lfs = require("libs/libkoreader-lfs")
local Popups = require("popups")
local Settings = require("dotdash_settings")
local Skull = require("skull")
local StatsPage = require("stats")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Window = require("window")

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local floor = math.floor

local skull_cache = {}   -- "path|scale" -> BB, kept between Dashboard instances

local function cachedSkull(path, scale)
    local key = path .. "|" .. scale
    if skull_cache[key] == nil then
        skull_cache[key] = Skull.load(path, scale) or false
    end
    return skull_cache[key] or nil
end

-- Visible part of skull.png (logical dots)
local ART_W, ART_H = 270, 320
local ART_X, ART_Y = 22, 40

local BAR_W = 50                           -- library window width
local M, GAP = 4, 6                        -- screen margin, gap between windows
local COVER_W, COVER_H, COVER_GAP = 36, 50, 4
local ARROW_H = 12
local PAGE = 4                             -- covers visible at once
local TITLE_LINES = 2
local READING_BAR_H = 14                   -- progress bar height in reading card

local MIN_W = M + (ART_W + 2 * (Window.FRAME + Window.PAD)) + GAP + BAR_W + M

-- Monospace font: try a few known names, fall back to the default font.
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

-- Bold monospace fonts first (closer to the 1-bit look), then the usual one.
local TAB_FONTS = {
    "NotoSansMono-Bold.ttf", "FreeMonoBold.ttf",
    "DejaVuSansMono-Bold.ttf", "DroidSansMono.ttf",
}
local function tabFace(size)
    for _, name in ipairs(TAB_FONTS) do
        local ok, face = pcall(Font.getFace, Font, name, size)
        if ok and face then return face end
    end
    return monoFace(size)
end

-- Circle of the tabs (same shape as the one in the windows)
local TAB_RING = {
    ".###.", "#...#", "#...#", "#...#", ".###.",
}

local function measure(text, face)
    local tw = TextWidget:new{ text = text, face = face }
    local w = tw:getSize().w
    tw:free()
    return w
end

-- Greedy word wrap. The last allowed line takes all remaining words and
-- gets an ellipsis (via max_width) if it still does not fit.
local function wrapTitle(text, face, max_w, max_lines)
    local words = {}
    for word in text:gmatch("%S+") do words[#words + 1] = word end
    local lines, i = {}, 1
    while i <= #words and #lines < max_lines do
        if #lines == max_lines - 1 then
            lines[#lines + 1] = table.concat(words, " ", i)
            break
        end
        local line = words[i]
        i = i + 1
        while i <= #words and measure(line .. " " .. words[i], face) <= max_w do
            line = line .. " " .. words[i]
            i = i + 1
        end
        lines[#lines + 1] = line
    end
    if #lines == 0 then lines[1] = " " end
    return lines
end

-- A text widget pair: white copy (used as a halo) and black copy.
local function haloText(text, face, max_w)
    return {
        dark = TextWidget:new{ text = text, face = face, max_width = max_w, fgcolor = WHITE },
        halo = TextWidget:new{ text = text, face = face, max_width = max_w, fgcolor = BLACK },
    }
end

local function formatBytes(b)
    if b >= 1e9 then return string.format("%.1fG", b / 1e9) end
    return string.format("%dM", floor(b / 1e6))
end

local function readNumber(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local v = tonumber(f:read("*l"))
    f:close()
    return v
end

-- Temperature in °C from sysfs: battery first, then any power supply,
-- then the first thermal zone. Returns nil if nothing can be read.
local function readTemp()
    local paths = { "/sys/class/power_supply/battery/temp" }
    pcall(function()
        for name in lfs.dir("/sys/class/power_supply") do
            if name ~= "." and name ~= ".." then
                paths[#paths + 1] = "/sys/class/power_supply/" .. name .. "/temp"
            end
        end
    end)
    paths[#paths + 1] = "/sys/class/thermal/thermal_zone0/temp"
    for _, path in ipairs(paths) do
        local v = readNumber(path)
        if v and v ~= 0 then
            local c = v
            if v >= 1000 then c = v / 1000 elseif v >= 100 then c = v / 10 end
            if c > -20 and c < 100 then return c end
        end
    end
    return nil
end

local function inside(r, pos)
    return pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local Dashboard = InputContainer:extend{
    name = "dotdash_dashboard",
    covers_fullscreen = true,
    plugin_path = nil,
    reader_ui = nil,   -- the FileManager or ReaderUI instance that owns the plugin
}

function Dashboard:pxRect(lx, ly, lw, lh)
    local s = self.s
    return Geom:new{ x = self.ox + lx * s, y = self.oy + ly * s, w = lw * s, h = lh * s }
end

function Dashboard:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.suspended = W > H
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }

    -- Integer dot size, then a logical canvas centered on the screen
    local s = math.max(1, floor(W / MIN_W))
    self.s = s
    -- Small, reusable landscape status label.  The portrait dashboard itself
    -- remains suspended, but the user gets feedback instead of a blank screen.
    self.landscape_notice_title = TextWidget:new{
        text = "OBSCURUS PAUSED", face = monoFace(math.max(10, s * 5)), fgcolor = BLACK,
    }
    self.landscape_notice_hint = TextWidget:new{
        text = "ROTATE TO PORTRAIT", face = monoFace(math.max(8, s * 4)), fgcolor = BLACK,
    }
    local Wl, Hl = floor(W / s), floor(H / s)
    self.ox = floor((W - Wl * s) / 2)
    self.oy = floor((H - Hl * s) / 2)

    -- Windows
    local bar_x = Wl - M - BAR_W
    local left_w = bar_x - GAP - M
    local skull_h = ART_H + Window.CHROME
    local read_y = M + skull_h + GAP
    self.win_skull = Window.new(M, M, left_w, skull_h, BLACK, s)
    self.win_read = Window.new(M, read_y, left_w, Hl - M - read_y, WHITE, s)
    self.win_lib = Window.new(bar_x, M, BAR_W, Hl - 2 * M, WHITE, s)

    self.skull = cachedSkull(self.plugin_path .. "/skull.png", s)
    self.skull2 = cachedSkull(self.plugin_path .. "/skull2.png", s)   -- open mouth
    self.mouth_open = false
    -- Tabs inside the title strip of the skull window, right after its circle.
    -- Each letter is drawn in a fixed-width cell (monospaced look) and every
    -- tab has the same width: the one of the longest label.
    self.tabs = {}
    local tab_face = tabFace(math.floor(4 * s))
    local TAB_PAD, TAB_GAP = 4, 4   -- dots
    local cell = 0
    for _, def in ipairs({ { "statistics", "openStats" }, { "explorer", "openExplorer" } }) do
        local tab = { action = def[2], chars = {} }
        for ch in def[1]:gmatch(".") do
            local tw = TextWidget:new{ text = ch, face = tab_face }
            cell = math.max(cell, tw:getSize().w)
            tab.chars[#tab.chars + 1] = tw
        end
        self.tabs[#self.tabs + 1] = tab
    end
    -- Real vertical extent of capital letters: the text line box has empty
    -- space above/below them, so the labels are centered by their glyphs.
    local cap_top, cap_bot
    do
        local tw = TextWidget:new{ text = "lp", face = tab_face }
        local sz = tw:getSize()
        local probe = Blitbuffer.new(sz.w, sz.h, Blitbuffer.TYPE_BB8)
        probe:fill(WHITE)
        tw:paintTo(probe, 0, 0)
        for y = 0, sz.h - 1 do
            for x = 0, sz.w - 1 do
                if probe:getPixel(x, y):getColor8().a < 128 then
                    cap_top = cap_top or y
                    cap_bot = y
                end
            end
        end
        probe:free()
        tw:free()
    end
    cap_top, cap_bot = cap_top or 0, cap_bot or 0
    local cap_h = cap_bot - cap_top + 1

    -- Chip height from the text, centered in the white bar of the window
    local sw = self.win_skull
    local bar_h = Window.TITLE_H + Window.PAD
    local chip_h = math.min(bar_h - 2, math.ceil(cap_h / s) + 2)
    local chip_y = sw.y + Window.FRAME + floor((bar_h - chip_h) / 2)
    local tab_x = sw.x + Window.FRAME + 3 + 7 + 5      -- after the 7-dot circle
    for _, tab in ipairs(self.tabs) do
        tab.cell = cell
        tab.text_dots = math.ceil(cell * #tab.chars / s)  -- own text width
        tab.text_x = TAB_PAD
        tab.cap_top, tab.cap_h = cap_top, cap_h
        tab.x, tab.y = tab_x, chip_y
        tab.w = tab.text_dots + 2 * TAB_PAD
        tab.h = chip_h
        tab_x = tab_x + tab.w + TAB_GAP
    end

    self.files = Books.history(true)
    self.library = last_library or {}
    self.library_scan = nil
    self.offset = Settings.keepLibraryPage()
       and math.min(last_offset, math.max(0, #self.library - PAGE)) or 0

    self:layoutLibrary()
    self:layoutReading()
    self:readInfo()

    self.popups = Popups.new{
        scale = s, ox = self.ox, oy = self.oy,
        canvas_w = Wl, canvas_h = Hl, face_fn = monoFace,
        get_info = function() return self.info end,
        get_book = function()
            if not self.files[1] then return nil end
            return { title = self.book_title, progress = self.progress }
        end,
        refresh = function(region) UIManager:setDirty(self, "ui", region) end,
        open_file = function(file) self:openBook(file) end,
        on_library_changed = function() self:reloadLibrary() end,
    }

    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    self.queue = {}
    self:startLoading()
    self:startClock()
    self:startLibraryScan()
end

-- Scan the home folder in small batches after the dashboard is visible.
function Dashboard:startLibraryScan()
    if self.library_task then UIManager:unschedule(self.library_task) end
    if self.library_scan then Books.closeHomeScan(self.library_scan) end
    self.library_generation = (self.library_generation or 0) + 1
    local generation = self.library_generation
    self.library_scan = Books.beginHomeScan()
    self.library_task = function() self:loadLibraryBatch(generation) end
    UIManager:scheduleIn(0.05, self.library_task)
end

function Dashboard:loadLibraryBatch(generation)
    if self.closed or self.suspended or generation ~= self.library_generation then return end
    local done, list = Books.homeScanBatch(self.library_scan, 12)
            if done then
        local old_offset = self.offset
        local changed = #list ~= #self.library
        if not changed then
            for i = 1, #list do
                if list[i] ~= self.library[i] then changed = true break end
            end
        end
        self.library = list
        last_library = list
        self.library_scan = nil
        self.library_task = nil
        self.offset = Settings.keepLibraryPage()
            and math.min(self.offset, math.max(0, #list - PAGE)) or 0
        last_offset = self.offset
        if changed or self.offset ~= old_offset then
            self:startLoading()
            UIManager:setDirty(self, "ui", self:pxRect(
                self.win_lib.x, self.win_lib.y, self.win_lib.w + Window.SHADOW,
                self.win_lib.h + Window.SHADOW))
        end
    else
        UIManager:scheduleIn(0.03, self.library_task)
    end
end

-- Library window, top to bottom: info panel, up arrow, 4 covers, down arrow.
function Dashboard:layoutLibrary()
    local lw = self.win_lib
    self.per_page = PAGE

    local dn_y = lw.cy + lw.ch - ARROW_H
    local block_h = PAGE * COVER_H + (PAGE - 1) * COVER_GAP
    self.slot_x = lw.cx + floor((lw.cw - COVER_W) / 2)
    self.slot_y0 = dn_y - 2 - block_h
    local up_y = self.slot_y0 - 2 - ARROW_H
    self.up_y, self.dn_y = up_y, dn_y

    self.up_rect = self:pxRect(lw.cx, up_y, lw.cw, ARROW_H)
    self.down_rect = self:pxRect(lw.cx, dn_y, lw.cw, ARROW_H)

    -- Info panel fills everything above the up arrow
    local top = lw.cy + 2
    self.info_rect = { x = lw.cx + 1, y = top, w = lw.cw - 2, h = up_y - 3 - top }
end

function Dashboard:slot(i)
    return self.slot_x, self.slot_y0 + (i - 1) * (COVER_H + COVER_GAP)
end

-- Free the text widgets of the current reading card. Safe to call when
-- nothing has been built yet.
function Dashboard:freeReadingText()
    for _, line in ipairs(self.title_lines or {}) do
        line.dark:free()
        line.halo:free()
    end
    if self.pct then
        self.pct.dark:free()
        self.pct.halo:free()
    end
    self.title_lines = {}
    self.pct = nil
end

function Dashboard:layoutReading()
    self:freeReadingText()

    local s = self.s
    local rw = self.win_read
    local h = math.min(rw.ch - 8, 110)
    local w = floor(h * COVER_W / COVER_H)
    self.rc = { x = rw.cx + 4, y = rw.cy + 4, w = w, h = h }
    self.text_x = rw.cx + 4 + w + 6
    self.text_w = rw.cw - (self.text_x - rw.cx) - 4

    local file = self.files[1]
    self.progress = file and Books.progress(file) or 0

    local face = monoFace(7 * s)
    local max_w = (self.text_w - 4) * s
    local title = file and Books.title(file) or "No books yet"
    self.book_title = title
    self.title_lines = {}
    for _, line in ipairs(wrapTitle(title, face, max_w, TITLE_LINES)) do
        table.insert(self.title_lines, haloText(line, face, max_w))
    end
    self.pct = haloText(string.format("%d%%", floor(self.progress * 100 + 0.5)), face)

    -- Compute geometry of the title / percent / progress-bar group once and
    -- cache it here, so paintReading and tap handling share the same numbers.
    self.line_h = math.ceil(self.title_lines[1].dark:getSize().h / s)
    self.pct_h = math.ceil(self.pct.dark:getSize().h / s)
    local py, ph = self.rc.y - 1, self.rc.h + 2
    local group_h = #self.title_lines * self.line_h + 8 + self.pct_h + 3 + READING_BAR_H
    local y = py + floor((ph - group_h) / 2)
    self.group_y = y
    self.open_rect = { x = self.text_x, y = y - 4, w = self.text_w, h = group_h + 8 }
end

-- Reads the data shown in the info panel. Every source is optional.
function Dashboard:readInfo()
    local info = {
        time = os.date("%H:%M"),
        weekday = os.date("%A"),
        date = tonumber(os.date("%d")) .. " " .. os.date("%b"),
    }
    pcall(function()
        local pd = Device:getPowerDevice()
        info.batt = tonumber(pd:getCapacity())
        if Device:hasFrontlight() then
            info.light = tonumber(pd:frontlightIntensity())
        end
        info.charging = pd:isCharging() and true or false
    end)
    pcall(function()
        if Device:hasWifiToggle() then
            local NetworkMgr = require("ui/network/manager")
            info.wifi = NetworkMgr:isWifiOn() and "ON" or "OFF"
        end
    end)
    pcall(function()
        local usage = require("util").diskUsage(require("datastorage"):getDataDir())
        if usage and usage.available then info.free = formatBytes(usage.available) end
    end)
    pcall(function() info.temp = readTemp() end)
    self.info = info
end

-- KOReader broadcasts this event whenever the frontlight intensity changes,
-- so the info panel can update the GLOW value instantly instead of waiting
-- for the next clock tick.
function Dashboard:onFrontlightStateChanged()
    if not Device:hasFrontlight() then return end
    local ok, value = pcall(function()
        return tonumber(Device:getPowerDevice():frontlightIntensity())
    end)
    self.info.light = ok and value or nil
    -- Repaint only the info panel (battery/temp/free don't change here)
    local r = self.info_rect
    if r then
        UIManager:setDirty(self, "ui", self:pxRect(r.x, r.y, r.w, r.h))
    end
end

-- Refresh the panel once a minute, aligned to the minute change.
function Dashboard:startClock()
    self.clock_task = function()
        if self.closed or self.suspended then return end
        self:readInfo()
        local r = self.info_rect
        UIManager:setDirty(self, "ui", self:pxRect(r.x, r.y, r.w, r.h))
        self.popups:refreshLive()
        UIManager:scheduleIn(60, self.clock_task)
    end
    local wait = math.max(1, 61 - tonumber(os.date("%S")))
    UIManager:scheduleIn(wait, self.clock_task)
end

-- White outline around the text so it stays readable over the shading.
function Dashboard:paintHaloText(bb, t, x, y)
    local d = math.max(1, floor(self.s * 2 / 3))
    for dx = -d, d, d do
        for dy = -d, d, d do
            if dx ~= 0 or dy ~= 0 then t.halo:paintTo(bb, x + dx, y + dy) end
        end
    end
    t.dark:paintTo(bb, x, y)
end

function Dashboard:paintReading(bb, ox, oy)
    local s = self.s
    local rw = self.win_read
    local function rect(x, y, w, h, c)
        bb:paintRect(ox + x * s, oy + y * s, w * s, h * s, c)
    end

    -- Whole card shaded with the dither pattern
    Dither.fill(bb, ox + rw.cx * s, oy + rw.cy * s, rw.cw * s, rw.ch * s, 0.5, s)

    -- Cover with a thin white border so it stands out from the shading
    local rc = self.rc
    if self.files[1] then
        rect(rc.x - 1, rc.y - 1, rc.w + 2, rc.h + 2, WHITE)
        local cover = Covers.peek(self.files[1], rc.w, rc.h, s, Settings.ditherRecent())
        bb:blitFrom(cover, ox + rc.x * s, oy + rc.y * s, 0, 0, rc.w * s, rc.h * s)
    end

    -- Title lines + percentage + bar, centered as a group next to the cover.
    -- Geometry was computed in layoutReading.
    local cx = ox + (self.text_x + floor(self.text_w / 2)) * s
    local y = self.group_y

    for _, line in ipairs(self.title_lines) do
        local w = line.dark:getSize().w
        self:paintHaloText(bb, line, cx - floor(w / 2), oy + y * s)
        y = y + self.line_h
    end
    y = y + 8
    self:paintHaloText(bb, self.pct, cx - floor(self.pct.dark:getSize().w / 2), oy + y * s)
    y = y + self.pct_h + 3

    -- Progress bar: thick frame, segments; empty segments use the dither
    local bar_h = READING_BAR_H
    local bw = self.text_w - 16
    local bx = self.text_x + 8
    rect(bx, y, bw, bar_h, BLACK)
    rect(bx + 2, y + 2, bw - 4, bar_h - 4, WHITE)
    local inner_w = bw - 6
    local pitch = 6
    local count = math.max(1, floor((inner_w + 1) / pitch))
    local used = count * pitch - 1
    local sx = bx + 3 + floor((inner_w - used) / 2)
    local filled = floor(self.progress * count + 0.5)
    for i = 0, count - 1 do
        local x = sx + i * pitch
        if i < filled then
            rect(x, y + 3, 5, bar_h - 6, BLACK)
        else
            Dither.fill(bb, ox + x * s, oy + (y + 3) * s, 5 * s, (bar_h - 6) * s, 0.7, s)
        end
    end
end

-- Info panel: [LABEL] in bold with its value below, evenly spaced and
-- separated by dotted lines. Sections without data are skipped.
function Dashboard:paintInfo(bb, ox, oy)
    local s = self.s
    local r = self.info_rect
    local info = self.info
    local label_face = monoFace(4 * s)
    local data_face = monoFace(4 * s)
    local max_w = (r.w - 2) * s

    local widgets = {}
    local function section(label, value)
        local l = TextWidget:new{
            text = "[" .. label .. "]", face = label_face, bold = true, max_width = max_w,
        }
        local v = TextWidget:new{ text = value, face = data_face, max_width = max_w }
        widgets[#widgets + 1] = l
        widgets[#widgets + 1] = v
        return { l, v }
    end

    local sections = {
        section("TIME", info.time),
        section("DATE", info.date),
    }
    if info.batt then
        sections[#sections + 1] = section("BATT",
            floor(info.batt) .. "%" .. (info.charging and "+" or ""))
    end
    if info.light then
        sections[#sections + 1] = section("GLOW", floor(info.light) .. "%")
    end
    if info.temp then
        sections[#sections + 1] = section("TEMP", string.format("%.0f°C", info.temp))
    end
    if info.free then
        sections[#sections + 1] = section("FREE", info.free)
    end

    -- Heights in dots
    local total = 0
    for _, sec in ipairs(sections) do
        sec.lh = math.ceil(sec[1]:getSize().h / s)
        sec.vh = math.ceil(sec[2]:getSize().h / s)
        sec.h = sec.lh + 1 + sec.vh
        total = total + sec.h
    end

    -- Spread the free space evenly around the separators
    local n = #sections
    local g = 4
    if n > 1 then
        g = floor((r.h - total - (n - 1) - 8) / (2 * (n - 1)))
        g = math.max(2, math.min(8, g))
    end
    local used = total + (n - 1) * (2 * g + 1)
    local y = r.y + math.max(0, floor((r.h - used) / 2))
    local cx = ox + (r.x + floor(r.w / 2)) * s

    for idx, sec in ipairs(sections) do
        local l, v = sec[1], sec[2]
        l:paintTo(bb, cx - floor(l:getSize().w / 2), oy + y * s)
        v:paintTo(bb, cx - floor(v:getSize().w / 2), oy + (y + sec.lh + 1) * s)
        y = y + sec.h
        if idx < n then
            y = y + g
            Dither.fill(bb, ox + (r.x + 3) * s, oy + y * s, (r.w - 6) * s, s, 0.5, s)
            y = y + 1 + g
        end
    end

    for _, tw in ipairs(widgets) do tw:free() end
end

function Dashboard:paintLibrary(bb, ox, oy)
    local s = self.s
    local lw = self.win_lib
    local function rect(x, y, w, h, c)
        bb:paintRect(ox + x * s, oy + y * s, w * s, h * s, c)
    end
    local mid = lw.cx + floor(lw.cw / 2)

    -- Up arrow (above the covers) and down arrow (below them)
    for i = 0, 4 do rect(mid - i, self.up_y + 3 + i, 2 * i + 1, 1, BLACK) end
    for i = 0, 4 do rect(mid - (4 - i), self.dn_y + 4 + i, 2 * (4 - i) + 1, 1, BLACK) end

    -- Cover slots (all the same size)
    for i = 1, self.per_page do
        local file = self.library[self.offset + i]
        if file then
            local x, y = self:slot(i)
            local cover = Covers.peek(file, COVER_W, COVER_H, s, Settings.ditherBar())
            bb:blitFrom(cover, ox + x * s, oy + y * s, 0, 0, COVER_W * s, COVER_H * s)
        end
    end
end

function Dashboard:paintLandscapeNotice(bb, x, y)
    local title = self.landscape_notice_title
    local hint = self.landscape_notice_hint
    if not title or not hint then return end

    local ts, hs = title:getSize(), hint:getSize()
    local pad_x, pad_y, gap = 14, 10, 6
    local box_w = math.max(ts.w, hs.w) + 2 * pad_x
    local box_h = ts.h + hs.h + 2 * pad_y + gap
    local bx = x + math.floor((Screen:getWidth() - box_w) / 2)
    local by = y + math.floor((Screen:getHeight() - box_h) / 2)

    -- Draw only a compact status card.  The FileManager underneath remains
    -- visible; no portrait coordinates or full-screen white fill are used.
    bb:paintRect(bx, by, box_w, box_h, BLACK)
    bb:paintRect(bx + 1, by + 1, box_w - 2, box_h - 2, WHITE)
    title:paintTo(bb, bx + math.floor((box_w - ts.w) / 2), by + pad_y)
    hint:paintTo(bb, bx + math.floor((box_w - hs.w) / 2), by + pad_y + ts.h + gap)
end

function Dashboard:paintTo(bb, x, y)
    -- SetDimensions is normally broadcast by KOReader on rotation.  Check the
    -- live screen size as a fallback so a missed/late event cannot make the
    -- portrait canvas paint over a landscape framebuffer.
    local landscape = Screen:getWidth() > Screen:getHeight()
    if landscape ~= self.suspended then
        self:onSetDimensions()
    end
    if self.suspended then
        self:paintLandscapeNotice(bb, x, y)
        return
    end
    local s, ox, oy = self.s, x + self.ox, y + self.oy
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, WHITE)

    -- Skull window
    local w = self.win_skull
    w:paint(bb, ox, oy)
    local art = (self.mouth_open and self.skull2) or self.skull
    if art then
        local aw = math.min(ART_W, w.cw)
        local ah = math.min(ART_H, w.ch)
        local sx = ART_X + floor((ART_W - aw) / 2)
        local dx = w.cx + floor((w.cw - aw) / 2)
        bb:blitFrom(art, ox + dx * s, oy + w.cy * s, sx * s, ART_Y * s, aw * s, ah * s)
    end
    -- Tabs: black chips inside the title strip. Painted white with black text,
    -- then inverted so the text ends up white on black.
    for _, t in ipairs(self.tabs) do
        local x, y, w, h = ox + t.x * s, oy + t.y * s, t.w * s, t.h * s
        bb:paintRect(x, y, w, h, WHITE)
        local text_w = #t.chars * t.cell
        local tx = x + t.text_x * s + floor((t.text_dots * s - text_w) / 2)
        local ty = y + floor((h - t.cap_h) / 2) - t.cap_top
        for i, tw in ipairs(t.chars) do
            local gw = tw:getSize().w
            tw:paintTo(bb, tx + (i - 1) * t.cell + floor((t.cell - gw) / 2), ty)
        end
        bb:invertRect(x, y, w, h)
    end

    self.win_read:paint(bb, ox, oy)
    self:paintReading(bb, ox, oy)

    self.win_lib:paint(bb, ox, oy)
    self:paintInfo(bb, ox, oy)
    self:paintLibrary(bb, ox, oy)
    self.popups:paint(bb, ox, oy)
end

-- Cover loading happens one cover at a time so the UI shows up right away.
function Dashboard:buildQueue()
    self.queue = {}
    local s = self.s
    local function push(file, w, h, region, dither)
        if file and not Covers.isLoaded(file, w, h, s, dither) then
            table.insert(self.queue, {
                file = file, w = w, h = h, region = region, dither = dither,
            })
        end
    end
    local rc = self.rc
    push(self.files[1], rc.w, rc.h, self:pxRect(rc.x, rc.y, rc.w, rc.h), Settings.ditherRecent())
    local bar_dither = Settings.ditherBar()
    for i = 1, self.per_page do
        local file = self.library[self.offset + i]
        if file then
            local x, y = self:slot(i)
            push(file, COVER_W, COVER_H, self:pxRect(x, y, COVER_W, COVER_H), bar_dither)
        end
    end
end

function Dashboard:startLoading()
    self:buildQueue()
    if self.load_task then UIManager:unschedule(self.load_task) end
    self.load_task = function() self:loadNext() end
    UIManager:scheduleIn(0.3, self.load_task)
end

function Dashboard:loadNext()
    if self.closed or self.suspended then return end
    local job = table.remove(self.queue, 1)
    if not job then self.load_task = nil return end
    Covers.load(job.file, job.w, job.h, self.s, job.dither)
    UIManager:setDirty(self, "ui", job.region)
    UIManager:scheduleIn(0.1, self.load_task)
end

-- Called when the home folder changes or a book is deleted
function Dashboard:reloadLibrary()
    self.files = Books.history(true)
    self.offset = 0
    last_offset = 0
    last_library = nil
    self:layoutReading()
    self.library = {}
    self:startLibraryScan()
    local lw, rw = self.win_lib, self.win_read
    UIManager:setDirty(self, "ui", self:pxRect(lw.x, lw.y, lw.w + Window.SHADOW, lw.h + Window.SHADOW))
    UIManager:setDirty(self, "ui", self:pxRect(rw.x, rw.y, rw.w + Window.SHADOW, rw.h + Window.SHADOW))
    self:startLoading()
end

-- Called from the menu when a dithered-covers option changes
function Dashboard:refreshCovers()
    self:startLoading()
    UIManager:setDirty(self, "ui", self.dimen)
end

function Dashboard:scroll(dir)
    local max_offset = math.max(0, #self.library - self.per_page)
    local new_offset = math.max(0, math.min(max_offset, self.offset + dir * self.per_page))
    if new_offset == self.offset then return end
    self.offset = new_offset
    last_offset = new_offset
    local lw = self.win_lib
    UIManager:setDirty(self, "ui", self:pxRect(lw.x, lw.y, lw.w + Window.SHADOW, lw.h + Window.SHADOW))
    self:startLoading()
end

function Dashboard:showChild(widget)
    UIManager:show(widget)
end

function Dashboard:openStats()
    self:showChild(StatsPage:new{
        scale = self.s, ox = self.ox, oy = self.oy,
        canvas_w = floor(self.dimen.w / self.s),
        canvas_h = floor(self.dimen.h / self.s),
        reader_ui = self.reader_ui,
    })
end

function Dashboard:openExplorer()
    self:showChild(Explorer:new{
        scale = self.s, ox = self.ox, oy = self.oy,
        canvas_w = floor(self.dimen.w / self.s),
        canvas_h = floor(self.dimen.h / self.s),
        reader_ui = self.reader_ui,
        open_file = function(file) self:openBook(file) end,
        on_library_changed = function() self:reloadLibrary() end,
    })
end

function Dashboard:openBook(file)
    if not file or lfs.attributes(file, "mode") ~= "file" then
        UIManager:show(require("ui/widget/infomessage"):new{
            text = "File not found:\n" .. tostring(file),
        })
        return
    end
    local reader_ui = self.reader_ui
    UIManager:close(self)
    UIManager:nextTick(function()
        if reader_ui and reader_ui.switchDocument then
            reader_ui:switchDocument(file)
        else
            require("apps/reader/readerui"):showReader(file)
        end
    end)
end

-- Opens the main KOReader menu above the dashboard. Opening it twice leaves
-- an orphan copy that a tap can't close, so do nothing if it is already open.
function Dashboard:showMenu()
    local menu = self.reader_ui and self.reader_ui.menu
    if not menu or menu.menu_container then return end
    if menu.onShowMenu then
        pcall(menu.onShowMenu, menu)
    end
end

-- The dashboard sits on top of the File Manager, so UIManager never hands
-- it the gestures. The Gestures plugin registers its touch zones on the
-- File Manager; offer them here. A zone handler only returns true when the
-- user configured an action for it.
function Dashboard:forwardGesture(ges)
    local ui = self.reader_ui
    local zones = ui and ui._ordered_touch_zones
    if not zones then return false end
    for _, tzone in ipairs(zones) do
        local id = tzone.def and tzone.def.id
        -- "filemanager_swipe" only pages the hidden file list: skip it
        if id ~= "filemanager_swipe"
            and (not UIManager._input_gestures_disabled
                 or ui:isGestureAlwaysActive(id, ges.multiswipe_directions))
            and tzone.gs_range:match(ges) then
            -- While the handler runs, the events it sends (Dispatcher
            -- actions) are handed to the File Manager by handleEvent
            self.forwarding = true
            local ok, handled = pcall(tzone.handler, ges)
            self.forwarding = false
            if not ok then
                require("logger").warn("dotdash: gesture handler failed", handled)
            elseif handled then
                return true
            end
        end
    end
    return false
end

-- UIManager:sendEvent stops at the top widget, so the events produced by
-- a gesture action never reach the File Manager modules underneath.
function Dashboard:handleEvent(event)
    if InputContainer.handleEvent(self, event) then return true end
    if self.forwarding and event.handler ~= "onGesture" and self.reader_ui then
        return self.reader_ui:handleEvent(event)
    end
    return false
end

function Dashboard:onGesture(ges)
    -- A SetDimensions event can be delayed on some backends.  Keep the input
    -- path in sync with the actual orientation before interpreting gestures.
    local landscape = Screen:getWidth() > Screen:getHeight()
    if landscape ~= self.suspended then
        self:onSetDimensions()
    end

    -- In landscape, preserve access to KOReader's top menu first.  Do not let
    -- a configured edge gesture consume the only easy way back to portrait.
    -- Obscurus hit targets are not valid in this orientation, so all other
    -- gestures are either forwarded to configured FileManager zones or passed
    -- through to KOReader.
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
        if self:forwardGesture(ges) then return true end
        return false
    end

    -- 1) the dashboard's own widgets (handlers return true only when used)
    if InputContainer.onGesture(self, ges) then return true end
    -- 2) the user's KOReader gestures (corners, edges, multiswipe...)
    if self:forwardGesture(ges) then return true end
    -- 3) top edge: open the KOReader menu
    if not UIManager._input_gestures_disabled then
        local H = self.dimen.h
        if (ges.ges == "tap" and ges.pos.y < H * 0.1)
            or (ges.ges == "swipe" and ges.direction == "south"
                and ges.pos.y < H * 0.15) then
            self:showMenu()
        end
    end
    return true
end

function Dashboard:onShow()
    -- The dashboard is a UI redraw, not a reason to force a full e-ink
    -- waveform. This avoids a white flash on wake and when returning from a book.
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function Dashboard:onTap(_, ges)
    local pos = ges.pos
    if self.suspended then
        if pos.y < Screen:getHeight() * 0.1 then
            self:showMenu()
            return true
        end
        return false
    end

    -- Popup windows sit above everything else
    local handled, region = self.popups:onTap(pos)
    if handled then
        if region then UIManager:setDirty(self, "ui", region) end
        return true
    end

    -- Tabs open the statistics window and the explorer
    for _, t in ipairs(self.tabs) do
        if inside(self:pxRect(t.x - 2, t.y - 3, t.w + 4, t.h + 6), pos) then
            self[t.action](self)
            return true
        end
    end

    -- Tap on the center of the skull: toggle between closed and open mouth
    if self.skull2 then
        local w = self.win_skull
        local aw = math.min(ART_W, w.cw)
        local ah = math.min(ART_H, w.ch)
        local dx = w.cx + floor((w.cw - aw) / 2)
        local zx, zy = dx + floor(aw / 4), w.cy + floor(ah / 4)
        local zw, zh = floor(aw / 2), floor(ah / 2)
        if inside(self:pxRect(zx, zy, zw, zh), pos) then
            local region = self:pxRect(dx, w.cy, aw, ah)
            self.mouth_open = true
            UIManager:setDirty(self, "ui", region)
            -- Close the mouth again after 1 second (a new tap restarts the timer)
            if self.mouth_task then UIManager:unschedule(self.mouth_task) end
            self.mouth_task = function()
                self.mouth_task = nil
                self.mouth_open = false
                UIManager:setDirty(self, "ui", region)
            end
            UIManager:scheduleIn(1, self.mouth_task)
            return true
        end
    end

    -- Navigation arrows
    if inside(self.up_rect, pos) then self:scroll(-1) return true end
    if inside(self.down_rect, pos) then self:scroll(1) return true end

    -- Library covers
    for i = 1, self.per_page do
        local file = self.library[self.offset + i]
        if file then
            local x, y = self:slot(i)
            if inside(self:pxRect(x, y, COVER_W, COVER_H), pos) then
                self:openBook(file)
                return true
            end
        end
    end

    -- Current book: only the title / percentage / progress bar open it
    local orc = self.open_rect
    if self.files[1] and orc and inside(self:pxRect(orc.x, orc.y, orc.w, orc.h), pos) then
        self:openBook(self.files[1])
        return true
    end

    -- Tap near the top edge: open the main menu
    if pos.y < self.dimen.h * 0.1 then
        self:showMenu()
    end
    return false
end

function Dashboard:onHold(_, ges)
    if self.suspended then return self:forwardGesture(ges) end
    -- A hold corner configured in the Gestures plugin wins over the menu
    if self:forwardGesture(ges) then return true end
    self.popups:onHold(ges.pos)
    return true
end

function Dashboard:onSwipe(_, ges)
    if self.suspended then
        if ges.direction == "south" and ges.pos.y < Screen:getHeight() * 0.15 then
            self:showMenu()
            return true
        end
        return false
    end
    return false
end

-- Pause rendering and background work in landscape, retaining the same
-- dashboard instance and portrait layout/state for the return rotation.
function Dashboard:onSetDimensions()
    local landscape = Screen:getWidth() > Screen:getHeight()
    if landscape == self.suspended then return end
    self.suspended = landscape

    -- The Dashboard overrides InputContainer:onGesture(), but refresh its
    -- gesture ranges too so any inherited/forwarded handling uses live bounds.
    local full = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = full } },
        Swipe = { GestureRange:new{ ges = "swipe", range = full } },
        Hold = { GestureRange:new{ ges = "hold", range = full } },
    }

    if landscape then
        -- Let KOReader paint the File Manager beneath us while preserving this
        -- dashboard instance and its state for the return to portrait.
        self.invisible = nil
        self.covers_fullscreen = false
        if self.library_task then UIManager:unschedule(self.library_task) end
        if self.load_task then UIManager:unschedule(self.load_task) end
        if self.clock_task then UIManager:unschedule(self.clock_task) end
        if self.mouth_task then UIManager:unschedule(self.mouth_task) end
        self.mouth_task = nil
        self.mouth_open = false
    else
        self.invisible = nil
        self.covers_fullscreen = true
        if self.library_task and self.library_scan then
            UIManager:scheduleIn(0.03, self.library_task)
        end
        if self.load_task then
            UIManager:scheduleIn(0.1, self.load_task)
        elseif self.queue and #self.queue > 0 then
            self:startLoading()
        end
        if self.clock_task then UIManager:scheduleIn(1, self.clock_task) end
    end
    -- Repaint the stack in normal UI mode. A forced full waveform causes an
    -- unnecessary white flash on e-ink devices when waking or changing views.
    UIManager:setDirty("all", "ui")
end

function Dashboard:onCloseWidget()
    self.closed = true
    if self.library_task then UIManager:unschedule(self.library_task) end
    if self.library_scan then Books.closeHomeScan(self.library_scan) end
    if self.load_task then UIManager:unschedule(self.load_task) end
    if self.clock_task then UIManager:unschedule(self.clock_task) end
    if self.mouth_task then UIManager:unschedule(self.mouth_task) end
    if self.landscape_notice_title then self.landscape_notice_title:free() end
    if self.landscape_notice_hint then self.landscape_notice_hint:free() end
    self:freeReadingText()
    for _, t in ipairs(self.tabs) do
        for _, tw in ipairs(t.chars) do tw:free() end
    end
    Dither.free()
    self.popups:free()
    -- Let KOReader redraw the underlying File Manager/Reader without forcing
    -- a full-screen e-ink flash just because the dashboard was closed.
    UIManager:setDirty(nil, "ui")
end

return Dashboard