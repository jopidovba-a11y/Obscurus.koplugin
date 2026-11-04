-- Popup windows drawn above the dashboard: add, move, resize and close.
-- Style: black frame, white window, and a black box with the information.
-- Positions and sizes are in logical dots and saved in KOReader's settings.
local Blitbuffer = require("ffi/blitbuffer")
local Books = require("books")
local Covers = require("covers")
local Data = require("statsdata")
local RenderImage = require("ui/renderimage")
local DataStorage = require("datastorage")
local Dither = require("dither")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Window = require("window")
local lfs = require("libs/libkoreader-lfs")

-- Colors are inverted on purpose: DRAW.* functions paint "black ink on
-- white paper", and the whole content box is inverted afterwards with
-- bb:invertRect(), ending up as white text on black.
local BLACK, WHITE = Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min

local GRID = 4          -- popups snap to this many dots
local STEP = 10         -- size change of the "Wider/Taller" buttons
local MIN_W = 44
local MIN_H = Window.CHROME + 12

-- Window types: name and three preset sizes (small, medium, large) in dots
local KINDS = {
    clock   = { name = "Clock",    sizes = { { 70, 40 }, { 100, 56 }, { 140, 80 } } },
    battery = { name = "Battery",  sizes = { { 60, 40 }, { 80, 54 }, { 110, 72 } } },
    files   = { name = "Files",    sizes = { { 110, 110 }, { 150, 150 }, { 200, 200 } } },
    alert   = { name = "Warning",  sizes = { { 80, 70 }, { 100, 86 }, { 130, 104 } } },
    jp      = { name = "Japanese", sizes = { { 70, 40 }, { 110, 56 }, { 160, 80 } } },
    text    = { name = "Message",  sizes = { { 90, 44 }, { 130, 60 }, { 190, 80 } } },
    speed   = { name = "Reading speed",      sizes = { { 80, 58 }, { 110, 72 }, { 150, 90 } } },
    versus  = { name = "Today vs yesterday", sizes = { { 110, 64 }, { 150, 76 }, { 200, 96 } } },
    week    = { name = "Last 7 days",        sizes = { { 110, 64 }, { 150, 84 }, { 220, 110 } } },
    streak  = { name = "Streak",             sizes = { { 80, 58 }, { 110, 72 }, { 150, 90 } } },
    todo    = { name = "To-do",              sizes = { { 100, 80 }, { 140, 110 }, { 190, 150 } } },
    loading = { name = "Loading",            sizes = { { 100, 52 }, { 130, 60 }, { 170, 72 } } },
    image   = { name = "Image",              sizes = { { 80, 80 }, { 120, 120 }, { 180, 180 } } },
}
local CATEGORIES = {
    { "Basic", { "clock", "battery", "text", "jp", "alert", "loading" } },
    { "Statistics", { "speed", "versus", "week", "streak" } },
    { "Tools", { "todo", "files", "image" } },
}
local IMAGE_EXT = { png = true, jpg = true, jpeg = true, bmp = true, gif = true,
                    webp = true, tif = true, tiff = true }
local TAP_EDIT = { text = true, jp = true }
local MENU_EDIT = { text = true, jp = true, alert = true }
local OPEN_EDITOR = { text = true }             
local DEFAULT_TEXT = { jp = "腐った", alert = "WARNING" }

local function clamp(v, lo, hi) return max(lo, min(hi, v)) end
local function snap(v) return floor(v / GRID + 0.5) * GRID end

local function inside(r, pos)
    return pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

-- Word wrap by character count (UTF-8 aware). Meant for a monospace font.
local function wrapText(text, cols)
    local lines = {}
    for par in (text .. "\n"):gmatch("(.-)\n") do
        if par == "" then
            lines[#lines + 1] = ""
        else
            local line, len = "", 0
            for word in par:gmatch("%S+") do
                local chars = {}
                for ch in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
                    chars[#chars + 1] = ch
                end
                if len > 0 and len + 1 + #chars <= cols then
                    line = line .. " " .. word
                    len = len + 1 + #chars
                else
                    if len > 0 then
                        lines[#lines + 1] = line
                        line, len = "", 0
                    end
                    for _, ch in ipairs(chars) do
                        if len >= cols then
                            lines[#lines + 1] = line
                            line, len = "", 0
                        end
                        line = line .. ch
                        len = len + 1
                    end
                end
            end
            if len > 0 then lines[#lines + 1] = line end
        end
    end
    return lines
end

-- Row(s) of {label, action} buttons in a standard KOReader dialog.
local function showButtons(title, rows)
    local ok, ButtonDialog = pcall(require, "ui/widget/buttondialog")
    if not ok then ButtonDialog = require("ui/widget/buttondialogtitle") end
    local dlg
    local buttons = {}
    for _, row in ipairs(rows) do
        local r = {}
        for _, b in ipairs(row) do
            r[#r + 1] = {
                text = b[1],
                callback = function()
                    UIManager:close(dlg)
                    b[2]()
                end,
            }
        end
        buttons[#buttons + 1] = r
    end
    dlg = ButtonDialog:new{ title = title, title_align = "center", buttons = buttons }
    UIManager:show(dlg)
end

local function homeDir() return Books.homeDir() end

local function joinPath(dir, name)
    if dir == "/" then return "/" .. name end
    return dir .. "/" .. name
end

local Popups = {}
Popups.__index = Popups

function Popups.new(opts)
    local self = setmetatable({}, Popups)
    self.s = opts.scale
    self.ox, self.oy = opts.ox, opts.oy
    self.canvas_w, self.canvas_h = opts.canvas_w, opts.canvas_h
    self.face_fn = opts.face_fn            -- monospace
    self.ui_face = function(size) return Font:getFace("cfont", size) end
    self.get_info = opts.get_info
    self.get_book = opts.get_book
    self.refresh = opts.refresh
    self.open_file = opts.open_file
    self.on_library_changed = opts.on_library_changed
    self.moving = nil
    self.todo_scroll = {}
    self.img_cache, self.img_count = {}, 0
    self.files_state = {}

    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/dotdash_popups.lua")
    self.list = self.settings:readSetting("popups") or {}
    self.next_id = 1
    -- Drop entries with unknown kind (e.g. after a downgrade) and track ids
    local kept = {}
    for _, p in ipairs(self.list) do
        if KINDS[p.kind] then
            kept[#kept + 1] = p
            self.next_id = max(self.next_id, (p.id or 0) + 1)
        end
    end
    self.list = kept
    self:rebuild()
    return self
end

-- Rebuilds the window objects and keeps every popup inside the canvas.
function Popups:rebuild()
    self.wins = {}
    for i, p in ipairs(self.list) do
        p.w = clamp(p.w, MIN_W, max(MIN_W, self.canvas_w - 2))
        p.h = clamp(p.h, MIN_H, max(MIN_H, self.canvas_h - 2))
        p.x = clamp(p.x, 0, max(0, self.canvas_w - p.w))
        p.y = clamp(p.y, 0, max(0, self.canvas_h - p.h))
        -- Black content box, "x" on the right (like the reference popups)
        self.wins[i] = Window.new(p.x, p.y, p.w, p.h, BLACK, self.s, true)
    end
end

function Popups:save()
    self.settings:saveSetting("popups", self.list)
    self.settings:flush()
end

function Popups:pxRect(lx, ly, lw, lh)
    local s = self.s
    return Geom:new{ x = self.ox + lx * s, y = self.oy + ly * s, w = lw * s, h = lh * s }
end

-- Screen region covering a window, its shadow and the move outline.
function Popups:rectOf(win, margin)
    local s, m = self.s, margin or 0
    return Geom:new{
        x = max(0, self.ox + (win.x - m) * s),
        y = max(0, self.oy + (win.y - m) * s),
        w = (win.w + 2 * m + Window.SHADOW) * s,
        h = (win.h + 2 * m + Window.SHADOW) * s,
    }
end

function Popups:indexOf(p)
    for i, q in ipairs(self.list) do
        if q == p then return i end
    end
end

-- ---------------------------------------------------------------- drawing

-- Largest text (between `hi` and `lo` dots of font size) that fits the box.
function Popups:fitText(text, max_w, max_h, hi, lo, face_fn, fg)
    face_fn = face_fn or self.face_fn
    fg = fg or WHITE
    local step = (hi - lo > 10) and 2 or 1
    for mul = hi, lo, -step do
        local tw = TextWidget:new{
            text = text, face = face_fn(floor(mul * self.s)), fgcolor = fg,
        }
        local size = tw:getSize()
        if size.w <= max_w and size.h <= max_h then return tw end
        tw:free()
    end
    return TextWidget:new{
        text = text, face = face_fn(floor(lo * self.s)), max_width = max_w, fgcolor = fg,
    }
end

-- Wrapped white text inside r = {x, y, w, h} (logical dots).
function Popups:paintWrapped(bb, ox, oy, r, text, mul, center, vcenter)
    local s = self.s
    local face = self.face_fn(floor(mul * s))
    local probe = TextWidget:new{ text = "0", face = face }
    local char_w, line_h = probe:getSize().w, probe:getSize().h
    probe:free()
    local cols = max(1, floor(r.w * s / char_w))
    local max_lines = max(1, floor(r.h * s / line_h))
    local lines = wrapText(text, cols)
    local count = min(#lines, max_lines)
    local y = oy + r.y * s
    if vcenter then y = y + floor((r.h * s - count * line_h) / 2) end
    local cx = ox + (r.x + floor(r.w / 2)) * s
    for n = 1, count do
        if lines[n] ~= "" then
            local tw = TextWidget:new{
                text = lines[n], face = face, max_width = r.w * s, fgcolor = WHITE,
            }
            local x = center and (cx - floor(tw:getSize().w / 2)) or (ox + r.x * s)
            tw:paintTo(bb, x, y)
            tw:free()
        end
        y = y + line_h
    end
end

local DRAW = {}
local POST = {}   -- drawn after the content box is inverted (images)

function DRAW.clock(self, bb, ox, oy, p, win)
    local s, info = self.s, self.get_info()
    local aw, ah = (win.cw - 6) * s, (win.ch - 6) * s
    local time_tw = self:fitText(info.time, aw, floor(ah * 0.65), 16, 5)
    local date_tw = self:fitText(info.weekday .. " " .. info.date, aw, floor(ah * 0.28), 7, 4)
    local ts, ds = time_tw:getSize(), date_tw:getSize()
    local gap = 2 * s
    local y = oy + win.cy * s + floor((win.ch * s - (ts.h + gap + ds.h)) / 2)
    local cx = ox + (win.cx + floor(win.cw / 2)) * s
    time_tw:paintTo(bb, cx - floor(ts.w / 2), y)
    date_tw:paintTo(bb, cx - floor(ds.w / 2), y + ts.h + gap)
    time_tw:free()
    date_tw:free()
end

function DRAW.battery(self, bb, ox, oy, p, win)
    local s, info = self.s, self.get_info()
    local function rect(x, y, w, h, c)
        bb:paintRect(ox + x * s, oy + y * s, w * s, h * s, c)
    end
    if not info.batt then
        self:paintWrapped(bb, ox, oy,
            { x = win.cx + 3, y = win.cy + 2, w = win.cw - 6, h = win.ch - 4 },
            "No battery data", 6, true, true)
        return
    end
    local pct = clamp(floor(info.batt), 0, 100)
    local margin = 4
    local inner_h = win.ch - 2 * margin
    local k = max(1, min(floor((win.cw - 10) / 18), floor((inner_h * 0.5 - 4) / 6)))
    local icon_h = 6 * k + 4
    local label = pct .. "%" .. (info.charging and "+" or "")
    local tw = self:fitText(label, (win.cw - 6) * s,
        max(8 * s, (inner_h - icon_h - 2) * s), 12, 4)
    local th = ceil(tw:getSize().h / s)
    local y0 = win.cy + margin + floor((inner_h - (icon_h + 2 + th)) / 2)
    local x0 = win.cx + floor((win.cw - (18 * k + 6)) / 2)
    rect(x0, y0, 18 * k + 4, icon_h, WHITE)
    rect(x0 + 2, y0 + 2, 18 * k, 6 * k, BLACK)
    rect(x0 + 2, y0 + 2, floor(pct / 100 * 18 * k + 0.5), 6 * k, WHITE)
    rect(x0 + 18 * k + 4, y0 + floor(icon_h / 3), 2, ceil(icon_h / 3), WHITE)
    local cx = ox + (win.cx + floor(win.cw / 2)) * s
    tw:paintTo(bb, cx - floor(tw:getSize().w / 2), oy + (y0 + icon_h + 2) * s)
    tw:free()
end

function DRAW.text(self, bb, ox, oy, p, win)
    local text = (p.text and p.text ~= "") and p.text or "(tap to edit)"
    self:paintWrapped(bb, ox, oy,
        { x = win.cx + 3, y = win.cy + 2, w = win.cw - 6, h = win.ch - 4 },
        text, 7, true, true)
end

-- Japanese text uses KOReader's regular font, which falls back to a CJK font.
function DRAW.jp(self, bb, ox, oy, p, win)
    local s = self.s
    local text = (p.text and p.text ~= "") and p.text or DEFAULT_TEXT.jp
    local tw = self:fitText(text, (win.cw - 8) * s, (win.ch - 6) * s, 28, 5, self.ui_face)
    local size = tw:getSize()
    local cx = ox + (win.cx + floor(win.cw / 2)) * s
    tw:paintTo(bb, cx - floor(size.w / 2),
        oy + win.cy * s + floor((win.ch * s - size.h) / 2))
    tw:free()
end


-- Warning popup: triangle with "!", optional message and an OK button.
function Popups:alertButton(win)
    local pad = 3
    local bw = clamp(floor(win.cw * 0.5), 24, max(24, win.cw - 2 * pad))
    return { x = win.cx + floor((win.cw - bw) / 2), y = win.cy + win.ch - 9 - pad, w = bw, h = 9 }
end

function DRAW.alert(self, bb, ox, oy, p, win)
    local s = self.s
    local function rect(x, y, w, h, c)
        bb:paintRect(ox + x * s, oy + y * s, w * s, h * s, c)
    end
    local btn = self:alertButton(win)
    local top = win.cy + 3
    local avail = btn.y - 3 - top
    local text = p.text or ""
    local show_text = text ~= "" and avail >= 40
    local tri_h = clamp(show_text and floor(avail * 0.6) or avail, 12, 44)
    local tri_w = floor(tri_h * 1.15)
    local cx = win.cx + floor(win.cw / 2)
    local ty = top + (show_text and 0 or floor((avail - tri_h) / 2))

    -- Triangle outline (2 dots thick) with a filled base
    for r = 0, tri_h - 1 do
        local half = floor(r * (tri_w / 2) / max(1, tri_h - 1))
        rect(cx - half, ty + r, 2, 1, WHITE)
        rect(cx + half - 1, ty + r, 2, 1, WHITE)
    end
    rect(cx - floor(tri_w / 2), ty + tri_h - 2, tri_w + 1, 2, WHITE)
    -- Exclamation mark
    local bar_h = max(3, floor(tri_h * 0.3))
    local bar_y = ty + floor(tri_h * 0.38)
    rect(cx - 1, bar_y, 2, bar_h, WHITE)
    rect(cx - 1, bar_y + bar_h + 2, 2, 2, WHITE)

    if show_text then
        local ty2 = ty + tri_h + 2
        self:paintWrapped(bb, ox, oy,
            { x = win.cx + 3, y = ty2, w = win.cw - 6, h = btn.y - 2 - ty2 },
            text, 6, true, true)
    end

    -- OK button
    rect(btn.x, btn.y, btn.w, btn.h, WHITE)
    rect(btn.x + 1, btn.y + 1, btn.w - 2, btn.h - 2, BLACK)
    local tw = self:fitText("OK", (btn.w - 4) * s, (btn.h - 2) * s, 8, 4)
    local size = tw:getSize()
    tw:paintTo(bb, ox + (btn.x + floor(btn.w / 2)) * s - floor(size.w / 2),
        oy + btn.y * s + floor((btn.h * s - size.h) / 2))
    tw:free()
end

-- File explorer: header (folder name), entries, footer with page arrows.
-- What is listed follows KOReader's own settings (hidden / unsupported files).
local function listingSignature()
    local hidden = G_reader_settings:isTrue("show_hidden")
    local unsupported = G_reader_settings:isTrue("show_unsupported")
    return (hidden and "h" or "-") .. (unsupported and "u" or "-")
end

local function entryLabel(e)
    if e.up then return "../" end
    if e.home then return "~ HOME" end
    return e.dir and ("/" .. e.name) or e.name
end

-- First and last pixel rows of a text widget that really contain ink.
local function inkRows(tw)
    local size = tw:getSize()
    local tmp = Blitbuffer.new(size.w, size.h)
    tmp:fill(Blitbuffer.COLOR_WHITE)
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

-- Title of the explorer window: the path, keeping its end. If it does not
-- fit, the start is replaced by ".." and the cut moves to the next "/".
local function titlePath(path, face, max_px)
    local tw = TextWidget:new{ text = path, face = face }
    if tw:getSize().w <= max_px then return tw end
    local ref = TextWidget:new{ text = "M", face = face }
    local char_w = max(1, ref:getSize().w)
    ref:free()
    local cut = ceil((tw:getSize().w - max_px) / char_w) + 2   -- characters to drop
    while true do
        tw:free()
        local start = cut + 1
        -- never cut inside a UTF-8 character
        while path:byte(start) and path:byte(start) >= 0x80 and path:byte(start) < 0xC0 do
            start = start + 1
        end
        local slash = path:find("/", start, true)   -- snap to a folder boundary
        if slash then start = slash end
        tw = TextWidget:new{ text = ".." .. path:sub(start), face = face }
        if tw:getSize().w <= max_px or start >= #path then return tw end
        cut = cut + 1
    end
end

-- Paints the current path in the white title strip, left of the "x".
-- Real black ink: the strip is outside the box that gets inverted.
function Popups:filesTitle(bb, ox, oy, win, st)
    local s, F = self.s, Window.FRAME
    local face = self.face_fn(floor(5 * s))
    local label = st.path
    if st.path == homeDir() then label = label .. " *" end
    local left = win.x + F + 3
    local right = win.x + win.w - F - 9 - 3          -- the "x" starts 9 dots before the frame
    local tw = titlePath(label, face, (right - left) * s)
    -- Center the capitals (not the whole text box) in the strip
    local ref = TextWidget:new{ text = "M", face = face }
    local top, bottom = inkRows(ref)
    ref:free()
    -- Center in the whole white band: title strip plus the gap above the content
    local strip_center = oy + (win.y + F) * s + floor((Window.TITLE_H + Window.PAD) * s / 2)
    tw:paintTo(bb, ox + left * s, floor(strip_center - (top + bottom + 1) / 2))
    tw:free()
end

function Popups:filesLayout(win)
    local rh = 14     -- row height: generous, so a tap hits the intended entry
    local x, w = win.cx + 3, win.cw - 6
    local y = win.cy + 2
    local rows = max(1, floor((win.ch - 4 - rh) / rh))
    return { x = x, w = w, rh = rh, list_y = y,
             rows = rows, footer_y = y + rows * rh }
end

function Popups:filesLoad(p)
    local path = p.path
    if not path or lfs.attributes(path, "mode") ~= "directory" then
        path = homeDir()
        p.path = path
    end
    local show_hidden = G_reader_settings:isTrue("show_hidden")
    local show_unsupported = G_reader_settings:isTrue("show_unsupported")
    local dirs, files = {}, {}
    pcall(function()
        local DocumentRegistry = require("document/documentregistry")
        for name in lfs.dir(path) do
            local hidden = name:sub(1, 1) == "."
            if name ~= "." and name ~= ".." and (show_hidden or not hidden) then
                local full = joinPath(path, name)
                local mode = lfs.attributes(full, "mode")
                if mode == "directory" then
                    -- Book metadata folders are never shown
                    if not name:match("%.sdr$") then dirs[#dirs + 1] = name end
                elseif mode == "file" then
                    if show_unsupported or DocumentRegistry:hasProvider(full) then
                        files[#files + 1] = name
                    end
                end
            end
        end
    end)
    local function ci(a, b) return a:lower() < b:lower() end
    table.sort(dirs, ci)
    table.sort(files, ci)
    local entries = {}
    if path ~= "/" then entries[#entries + 1] = { name = "..", dir = true, up = true } end
    if path ~= homeDir() then entries[#entries + 1] = { name = "HOME", dir = true, home = true } end
    for _, n in ipairs(dirs) do entries[#entries + 1] = { name = n, dir = true } end
    for _, n in ipairs(files) do entries[#entries + 1] = { name = n } end
    local st = { path = path, entries = entries, page = 1, sig = listingSignature() }
    self.files_state[p.id] = st
    return st
end

-- The listing is rebuilt when the folder or KOReader's settings change.
function Popups:filesState(p)
    local st = self.files_state[p.id]
    if not st or st.path ~= p.path or st.sig ~= listingSignature() then
        st = self:filesLoad(p)
    end
    return st
end

function DRAW.files(self, bb, ox, oy, p, win)
    local s = self.s
    local L = self:filesLayout(win)
    local st = self:filesState(p)
    local face = self.face_fn(floor(6 * s))
    local pages = max(1, ceil(#st.entries / L.rows))
    st.page = clamp(st.page, 1, pages)

    local function line(text, row_y, h_dots, fg, max_w_dots, centered)
        local tw = TextWidget:new{
            text = text, face = face, max_width = max_w_dots * s, fgcolor = fg,
        }
        local size = tw:getSize()
        local x = centered and (ox + (L.x + floor(L.w / 2)) * s - floor(size.w / 2))
            or (ox + (L.x + 1) * s)
        tw:paintTo(bb, x, oy + row_y * s + floor((h_dots * s - size.h) / 2))
        tw:free()
    end

    -- Current path in the white title strip of the window
    self:filesTitle(bb, ox, oy, win, st)

    -- Entries of the current page
    local first = (st.page - 1) * L.rows
    for n = 1, L.rows do
        local e = st.entries[first + n]
        if not e then break end
        line(entryLabel(e), L.list_y + (n - 1) * L.rh, L.rh, WHITE, L.w - 2)
    end

    -- Footer: page arrows
    line(string.format("<  %d/%d  >", st.page, pages), L.footer_y, L.rh, WHITE, L.w - 2, true)
end

-- --------------------------------------------------------- new windows

local function fmtDur(sec)
    local m = floor((sec or 0) / 60)
    if m < 60 then return m .. "m" end
    local h = floor(m / 60)
    if h >= 100 then return h .. "h" end
    return string.format("%dh%02d", h, m % 60)
end

-- Statistics, fetched through the shared statsdata cache (60 s TTL there).
function Popups:stats()
    local ok, d = pcall(Data.load, true)
    if ok and type(d) == "table" then
        return d
    end
    return { no_stats = true, error = ok and "Data.load returned nothing" or tostring(d) }
end

-- Paints a text widget at pixel (x, y) and frees it; returns its height.
function Popups:put(bb, tw, x, y, align)
    local size = tw:getSize()
    if align == "center" then
        x = x - floor(size.w / 2)
    elseif align == "right" then
        x = x - size.w
    end
    tw:paintTo(bb, x, y)
    tw:free()
    return size.h
end

function Popups:noData(bb, ox, oy, win)
    self:paintWrapped(bb, ox, oy,
        { x = win.cx + 3, y = win.cy + 2, w = win.cw - 6, h = win.ch - 4 },
        "NO STATISTICS DATA", 5, true, true)
end

-- Centered lines, one below the other. Each line is {text, hi, lo, share}.
-- If they do not fit, the least important lines are dropped (smallest share, last first).
function Popups:stack(bb, ox, oy, win, lines)
    local s = self.s
    local pad = 3
    local aw, ah = (win.cw - 2 * pad) * s, (win.ch - 2 * pad) * s
    local gap = 2 * s
    local list = {}
    for i, ln in ipairs(lines) do list[i] = ln end
    local tws, total
    while true do
        tws, total = {}, 0
        for i, ln in ipairs(list) do
            local tw = self:fitText(ln[1], aw, floor(ah * ln[4]), ln[2], ln[3])
            tws[i] = tw
            total = total + tw:getSize().h + (i > 1 and gap or 0)
        end
        if total <= ah or #list <= 1 then break end
        for _, tw in ipairs(tws) do tw:free() end
        local drop = #list
        for i = #list - 1, 1, -1 do
            if list[i][4] < list[drop][4] then drop = i end
        end
        table.remove(list, drop)
    end
    local y = oy + (win.cy + pad) * s + floor((ah - total) / 2)
    local cx = ox + (win.cx + floor(win.cw / 2)) * s
    for _, tw in ipairs(tws) do
        y = y + self:put(bb, tw, cx, y, "center") + gap
    end
end

function DRAW.speed(self, bb, ox, oy, p, win)
    local d = self:stats()
    if d.no_stats then return self:noData(bb, ox, oy, win) end
    local function pph(pages, secs)
        if secs <= 0 then return 0 end
        return pages / (secs / 3600)
    end
    local per_page = d.total_pages > 0 and d.total_secs / d.total_pages / 60 or 0
    self:stack(bb, ox, oy, win, {
        { "READING SPEED", 5, 3, 0.18 },
        { string.format("%d p/h", floor(pph(d.total_pages, d.total_secs) + 0.5)), 16, 6, 0.4 },
        { string.format("7 DAYS: %d p/h", floor(pph(d.week_pages, d.week_secs) + 0.5)), 6, 3, 0.18 },
        { string.format("%.1f min/page", per_page), 6, 3, 0.18 },
    })
end

function DRAW.versus(self, bb, ox, oy, p, win)
    local s, d = self.s, self:stats()
    if d.no_stats then return self:noData(bb, ox, oy, win) end
    local function rect(x, y, w, h, c)
        bb:paintRect(ox + x * s, oy + y * s, w * s, h * s, c)
    end
    local x0, w = win.cx + 3, win.cw - 6
    local today, yest = d.today_pages, d.yesterday_pages
    local delta = today - yest

    -- Caption and difference
    local cap_y = oy + (win.cy + 2) * s
    self:put(bb, self:fitText("PAGES", floor(w * s * 0.5), 9 * s, 5, 3), ox + x0 * s, cap_y, "left")
    local dtext = (delta > 0 and "+" or "") .. delta
    self:put(bb, self:fitText(dtext, floor(w * s * 0.4), 9 * s, 6, 3), ox + (x0 + w) * s, cap_y, "right")

    -- Two bars: today (solid) and yesterday (dotted)
    local rows_y = win.cy + 13
    local rh = floor((win.cy + win.ch - 2 - rows_y) / 2)
    local maxv = max(today, yest, 1)
    local bar_x, bar_w = x0 + 18, w - 18 - 17
    local items = { { "TODAY", today, true }, { "YEST.", yest, false } }
    for i, it in ipairs(items) do
        local ry = rows_y + (i - 1) * rh
        local lab = self:fitText(it[1], 17 * s, floor(rh * s * 0.8), 5, 3)
        local lh = lab:getSize().h
        self:put(bb, lab, ox + x0 * s, oy + ry * s + floor((rh * s - lh) / 2), "left")
        local num = self:fitText(tostring(it[2]), 16 * s, floor(rh * s * 0.8), 6, 3)
        local nh = num:getSize().h
        self:put(bb, num, ox + (x0 + w) * s, oy + ry * s + floor((rh * s - nh) / 2), "right")

        local bh = min(rh - 3, 9)
        local by = ry + floor((rh - bh) / 2)
        rect(bar_x, by, bar_w, bh, WHITE)
        rect(bar_x + 1, by + 1, bar_w - 2, bh - 2, BLACK)
        local fill = floor((bar_w - 4) * it[2] / maxv + 0.5)
        if fill > 0 then
            if it[3] then
                rect(bar_x + 2, by + 2, fill, bh - 4, WHITE)
            else
                Dither.fill(bb, ox + (bar_x + 2) * s, oy + (by + 2) * s, fill * s, (bh - 4) * s, 0.5, s)
            end
        end
    end
end

function DRAW.week(self, bb, ox, oy, p, win)
    local s, d = self.s, self:stats()
    if d.no_stats then return self:noData(bb, ox, oy, win) end
    local function rect(x, y, w, h, c)
        bb:paintRect(ox + x * s, oy + y * s, w * s, h * s, c)
    end
    local x0, w = win.cx + 3, win.cw - 6
    local cap_y = oy + (win.cy + 2) * s
    self:put(bb, self:fitText("LAST 7 DAYS", floor(w * s * 0.6), 9 * s, 5, 3), ox + x0 * s, cap_y, "left")
    self:put(bb, self:fitText(fmtDur(d.week_secs), floor(w * s * 0.35), 9 * s, 5, 3),
        ox + (x0 + w) * s, cap_y, "right")

    local series, maxv = {}, 1800
    for i = 6, 0, -1 do
        local t = d.noon - i * 86400
        local x = d.days[os.date("%Y-%m-%d", t)]
        local secs = x and x.secs or 0
        maxv = max(maxv, secs)
        series[#series + 1] = { secs = secs, name = os.date("%a", t):sub(1, 1), today = i == 0 }
    end
    local n, gap = 7, 3
    local bw = floor((w - gap * (n - 1)) / n)
    local bx0 = x0 + floor((w - (n * bw + (n - 1) * gap)) / 2)
    local base = win.cy + win.ch - 2 - 8
    local max_h = max(4, base - (win.cy + 12))
    rect(x0, base, w, 1, WHITE)
    for i, v in ipairs(series) do
        local bx = bx0 + (i - 1) * (bw + gap)
        local h = floor(v.secs / maxv * max_h + 0.5)
        if v.secs > 0 then h = max(h, 2) end
        if h > 0 then
            if v.today or h <= 2 then
                rect(bx, base - h, bw, h, WHITE)
            else
                Dither.fill(bb, ox + bx * s, oy + (base - h) * s, bw * s, h * s, 0.5, s)
                rect(bx, base - h, bw, 1, WHITE)
                rect(bx, base - 1, bw, 1, WHITE)
                rect(bx, base - h, 1, h, WHITE)
                rect(bx + bw - 1, base - h, 1, h, WHITE)
            end
        end
        local lab = self:fitText(v.name, (bw + gap) * s, 7 * s, 5, 3)
        self:put(bb, lab, ox + (bx + floor(bw / 2)) * s, oy + (base + 2) * s, "center")
    end
end

function DRAW.streak(self, bb, ox, oy, p, win)
    local s, d = self.s, self:stats()
    if d.no_stats then return self:noData(bb, ox, oy, win) end
    local function rect(x, y, w, h, c)
        bb:paintRect(ox + x * s, oy + y * s, w * s, h * s, c)
    end
    local show_days = win.ch >= 44
    local top = show_days and { cx = win.cx, cy = win.cy, cw = win.cw, ch = win.ch - 10 } or win
    self:stack(bb, ox, oy, top, {
        { "STREAK", 5, 3, 0.2 },
        { d.streak .. (d.streak == 1 and " DAY" or " DAYS"), 14, 6, 0.4 },
        { "BEST " .. d.best_streak, 6, 3, 0.2 },
    })
    if show_days then
        -- One square per day, oldest to newest; filled when you read
        local sq, pitch = 6, 8
        local sx = win.cx + floor((win.cw - (6 * pitch + sq)) / 2)
        local sy = win.cy + win.ch - 9
        for i = 0, 6 do
            local x = d.days[os.date("%Y-%m-%d", d.noon - (6 - i) * 86400)]
            local read = x and x.secs > 0
            rect(sx + i * pitch, sy, sq, sq, WHITE)
            rect(sx + i * pitch + 1, sy + 1, sq - 2, sq - 2, read and WHITE or BLACK)
        end
    end
end

-- Loading window: purely decorative bar with a CANCEL button that closes it
function DRAW.loading(self, bb, ox, oy, p, win)
    local s = self.s
    local function rect(x, y, w, h, c)
        bb:paintRect(ox + x * s, oy + y * s, w * s, h * s, c)
    end
    local value = clamp(p.value or 65, 0, 100)
    local x0, w = win.cx + 4, win.cw - 8
    local btn = self:alertButton(win)

    local top = win.cy + 3
    local cap = self:fitText("LOADING...", floor(w * s * 0.65), 9 * s, 6, 3)
    local cap_h = ceil(cap:getSize().h / s)
    self:put(bb, cap, ox + x0 * s, oy + top * s, "left")
    self:put(bb, self:fitText(value .. "%", floor(w * s * 0.3), 9 * s, 6, 3),
        ox + (x0 + w) * s, oy + top * s, "right")

    local bar_h = 9
    local free_top, free_bottom = top + cap_h + 2, btn.y - 3
    local by = free_top + max(0, floor((free_bottom - free_top - bar_h) / 2))
    rect(x0, by, w, bar_h, WHITE)
    rect(x0 + 1, by + 1, w - 2, bar_h - 2, BLACK)
    local pitch = 4
    local count = max(1, floor((w - 4 + 1) / pitch))
    local filled = floor(value / 100 * count + 0.5)
    for i = 0, count - 1 do
        local x = x0 + 2 + i * pitch
        if i < filled then
            rect(x, by + 2, 3, bar_h - 4, WHITE)
        else
            Dither.fill(bb, ox + x * s, oy + (by + 2) * s, 3 * s, (bar_h - 4) * s, 0.7, s)
        end
    end

    -- CANCEL button
    rect(btn.x, btn.y, btn.w, btn.h, WHITE)
    rect(btn.x + 1, btn.y + 1, btn.w - 2, btn.h - 2, BLACK)
    local tw = self:fitText("CANCEL", (btn.w - 4) * s, (btn.h - 2) * s, 8, 3)
    local th = tw:getSize().h
    self:put(bb, tw, ox + (btn.x + floor(btn.w / 2)) * s,
        oy + btn.y * s + floor((btn.h * s - th) / 2), "center")
end

-- To-do list: rows with a checkbox; tapping a row checks it and strikes it out
function Popups:todoLayout(win)
    local rh, fh = 10, 10
    local x, w = win.cx + 3, win.cw - 6
    local y = win.cy + 2
    local rows = max(1, floor((win.ch - 4 - fh) / rh))
    return { x = x, w = w, rh = rh, fh = fh, y = y, rows = rows, footer_y = y + rows * rh }
end

function DRAW.todo(self, bb, ox, oy, p, win)
    local s = self.s
    local function rect(x, y, w, h, c)
        bb:paintRect(ox + x * s, oy + y * s, w * s, h * s, c)
    end
    local L = self:todoLayout(win)
    p.items = p.items or {}
    local scroll = clamp(self.todo_scroll[p.id] or 0, 0, max(0, #p.items - L.rows))
    self.todo_scroll[p.id] = scroll
    local face = self.face_fn(floor(5 * s))

    for n = 1, L.rows do
        local item = p.items[scroll + n]
        if not item then break end
        local ry = L.y + (n - 1) * L.rh
        rect(L.x, ry + 2, 6, 6, WHITE)
        rect(L.x + 1, ry + 3, 4, 4, item.done and WHITE or BLACK)
        local tw = TextWidget:new{ text = item.text, face = face, max_width = (L.w - 9) * s }
        local size = tw:getSize()
        tw:paintTo(bb, ox + (L.x + 9) * s, oy + ry * s + floor((L.rh * s - size.h) / 2))
        if item.done then
            rect(L.x + 8, ry + 5, ceil(size.w / s) + 2, 1, WHITE)   -- strike-through
        end
        tw:free()
    end
    if #p.items == 0 then
        self:paintWrapped(bb, ox, oy, { x = L.x, y = L.y, w = L.w, h = L.rows * L.rh },
            "(no tasks)", 5, true, true)
    end

    -- Footer: add button and scroll arrows
    Dither.fill(bb, ox + L.x * s, oy + L.footer_y * s, L.w * s, s, 0.5, s)
    local fy = oy + L.footer_y * s
    local add = self:fitText("+ ADD", floor(L.w * s * 0.4), (L.fh - 1) * s, 5, 3)
    local ah = add:getSize().h
    self:put(bb, add, ox + (L.x + 1) * s, fy + s + floor(((L.fh - 1) * s - ah) / 2), "left")
    local arrows = self:fitText("<   >", floor(L.w * s * 0.4), (L.fh - 1) * s, 5, 3)
    local rh2 = arrows:getSize().h
    self:put(bb, arrows, ox + (L.x + L.w - 1) * s, fy + s + floor(((L.fh - 1) * s - rh2) / 2), "right")
end

function Popups:refreshPopup(p)
    local i = self:indexOf(p)
    if i then self.refresh(self:rectOf(self.wins[i], 3)) end
end

function Popups:askText(title, initial, on_save)
    local dlg
    dlg = InputDialog:new{
        title = title,
        input = initial or "",
        buttons = { {
            { text = "Cancel", callback = function() UIManager:close(dlg) end },
            { text = "Save", callback = function()
                local text = dlg:getInputText()
                UIManager:close(dlg)
                if text and text ~= "" then on_save(text) end
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function Popups:addTask(p)
    self:askText("New task", "", function(text)
        p.items = p.items or {}
        table.insert(p.items, { text = text, done = false })
        self:save()
        self:refreshPopup(p)
    end)
end

function Popups:editTask(p, item)
    self:askText("Edit task", item.text, function(text)
        item.text = text
        self:save()
        self:refreshPopup(p)
    end)
end

function Popups:deleteTask(p, item)
    for i, it in ipairs(p.items or {}) do
        if it == item then table.remove(p.items, i) break end
    end
    self:save()
    self:refreshPopup(p)
end

function Popups:clearDone(p)
    local kept = {}
    for _, it in ipairs(p.items or {}) do
        if not it.done then kept[#kept + 1] = it end
    end
    p.items = kept
    self:save()
    self:refreshPopup(p)
end

function Popups:todoScroll(p, delta)
    self.todo_scroll[p.id] = max(0, (self.todo_scroll[p.id] or 0) + delta)
    self:refreshPopup(p)
end

function Popups:todoTap(p, win, pos)
    local s = self.s
    local L = self:todoLayout(win)
    local lx, ly = (pos.x - self.ox) / s, (pos.y - self.oy) / s
    local items = p.items or {}
    if ly >= L.footer_y then
        local f = (lx - L.x) / L.w
        if f < 0.45 then
            self:addTask(p)
        elseif f < 0.75 then
            self:todoScroll(p, -L.rows)
        else
            self:todoScroll(p, L.rows)
        end
        return
    end
    local idx = (self.todo_scroll[p.id] or 0) + floor((ly - L.y) / L.rh) + 1
    if ly >= L.y and items[idx] then
        items[idx].done = not items[idx].done
        self:save()
        self.refresh(self:rectOf(win, 0))
    end
end

-- Hold on a task: edit or delete it. Returns false when not on a task.
function Popups:todoHold(p, win, pos)
    local s = self.s
    local L = self:todoLayout(win)
    local ly = (pos.y - self.oy) / s
    local items = p.items or {}
    local idx = (self.todo_scroll[p.id] or 0) + floor((ly - L.y) / L.rh) + 1
    if ly < L.y or ly >= L.footer_y or not items[idx] then return false end
    local item = items[idx]
    showButtons(item.text, {
        { { "Edit task", function() self:editTask(p, item) end } },
        { { "Delete task", function() self:deleteTask(p, item) end } },
        { { "Clear completed", function() self:clearDone(p) end } },
        { { "Cancel", function() end } },
    })
    return true
end

-- Image window: dithered picture, or "IMAGE NOT FOUND"
function Popups:freeImages()
    for _, c in pairs(self.img_cache) do
        if c then c.bb:free() end
    end
    self.img_cache, self.img_count = {}, 0
end

function Popups:free()
    self:freeImages()
end

function Popups:imageFor(p, win)
    if not p.path or lfs.attributes(p.path, "mode") ~= "file" then return nil end
    local mw, mh = win.cw - 6, win.ch - 6
    local key = p.path .. "|" .. mw .. "x" .. mh .. "@" .. self.s
    local c = self.img_cache[key]
    if c == nil then
        if self.img_count >= 6 then self:freeImages() end
        local src, small, out
        local ok, result = pcall(function()
            src = RenderImage:renderImageFile(p.path, false)
            if not src then return false end

            local sw, sh = src:getWidth(), src:getHeight()
            if sw <= 0 or sh <= 0 or mw <= 0 or mh <= 0 then
                return false
            end

            local k = min(mw / sw, mh / sh)
            local fw, fh = max(1, floor(sw * k)), max(1, floor(sh * k))
            small = RenderImage:scaleBlitBuffer(src, fw, fh, true)
            if not small then return false end

            out = Covers.dither(small, fw, fh, self.s)
            if not out then return false end

            -- Transfer ownership of the output buffer to img_cache.
            local result = { bb = out, w = fw, h = fh }
            out = nil
            return result
        end)

        -- renderImageFile() and scaleBlitBuffer() allocate native buffers.
        -- Release every temporary buffer even if scaling/dithering fails.
        if small then pcall(function() small:free() end) end
        if src then pcall(function() src:free() end) end
        if out then pcall(function() out:free() end) end

        c = (ok and result) or false
        self.img_cache[key] = c
        self.img_count = self.img_count + 1
    end
    return c or nil
end

function DRAW.image(self, bb, ox, oy, p, win)
    if self:imageFor(p, win) then return end   -- drawn after the inversion
    self:paintWrapped(bb, ox, oy,
        { x = win.cx + 3, y = win.cy + 2, w = win.cw - 6, h = win.ch - 4 },
        "IMAGE NOT FOUND", 6, true, true)
end

function POST.image(self, bb, ox, oy, p, win)
    local img = self:imageFor(p, win)
    if not img then return end
    local s = self.s
    bb:blitFrom(img.bb,
        ox + (win.cx + floor((win.cw - img.w) / 2)) * s,
        oy + (win.cy + floor((win.ch - img.h) / 2)) * s,
        0, 0, img.w * s, img.h * s)
end

function Popups:pickImage(p)
    local ok = pcall(function()
        local PathChooser = require("ui/widget/pathchooser")
        local start = p.path and p.path:match("^(.+)/[^/]+$") or Books.homeDir()
        UIManager:show(PathChooser:new{
            select_directory = false,
            select_file = true,
            path = start,
            file_filter = function(name)
                local ext = name:match("%.([^.]+)$")
                return ext ~= nil and IMAGE_EXT[ext:lower()] == true
            end,
            onConfirm = function(path)
                p.path = path
                self:save()
                self:refreshPopup(p)
            end,
        })
    end)
    if not ok then
        UIManager:show(InfoMessage:new{ text = "Could not open the file chooser." })
    end
end

function Popups:filesGo(p, win, path)
    p.path = path
    self.files_state[p.id] = nil
    self:save()
    self.refresh(self:rectOf(win, 0))
end

function Popups:filesTap(p, win, pos)
    local s = self.s
    local L = self:filesLayout(win)
    local st = self:filesState(p)
    local lx, ly = (pos.x - self.ox) / s, (pos.y - self.oy) / s
    local pages = max(1, ceil(#st.entries / L.rows))

    if ly >= L.footer_y and ly < L.footer_y + L.rh then
        if lx < L.x + L.w / 2 then
            st.page = max(1, st.page - 1)
        else
            st.page = min(pages, st.page + 1)
        end
        self.refresh(self:rectOf(win, 0))
    elseif ly >= L.list_y and ly < L.list_y + L.rows * L.rh then
        local idx = (st.page - 1) * L.rows + floor((ly - L.list_y) / L.rh) + 1
        local e = st.entries[idx]
        if not e then return end
        if e.home then
            self:filesGo(p, win, homeDir())
        elseif e.up then
            self:filesGo(p, win, st.path:match("^(.+)/[^/]+$") or "/")
        elseif e.dir then
            self:filesGo(p, win, joinPath(st.path, e.name))
        elseif self.open_file then
            self.open_file(joinPath(st.path, e.name))
        end
    end
end

-- Hold on an entry: actions for that file or folder. Returns false when the
-- hold was not on a real entry (the window menu opens instead).
function Popups:filesHold(p, win, pos)
    local s = self.s
    local L = self:filesLayout(win)
    local st = self:filesState(p)
    local ly = (pos.y - self.oy) / s
    if ly < L.list_y or ly >= L.list_y + L.rows * L.rh then return false end
    local idx = (st.page - 1) * L.rows + floor((ly - L.list_y) / L.rh) + 1
    local e = st.entries[idx]
    if not e or e.up or e.home then return false end
    local full = joinPath(st.path, e.name)
    if e.dir then
        showButtons(e.name, {
            { { "Set as home folder", function() self:setHome(full) end } },
            { { "Cancel", function() end } },
        })
    else
        showButtons(e.name, {
            { { "Delete file", function() self:confirmDelete(p, win, full) end } },
            { { "Set this folder as home", function() self:setHome(st.path) end } },
            { { "Cancel", function() end } },
        })
    end
    return true
end

function Popups:setHome(path)
    G_reader_settings:saveSetting("home_dir", path)
    G_reader_settings:flush()
    UIManager:show(InfoMessage:new{ text = "Home folder:\n" .. path, timeout = 2 })
    self.files_state = {}
    for i, q in ipairs(self.list) do
        if q.kind == "files" then self.refresh(self:rectOf(self.wins[i], 0)) end
    end
    if self.on_library_changed then self.on_library_changed() end
end

function Popups:confirmDelete(p, win, full)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = "Delete this file?\n\n" .. (full:match("([^/]+)$") or full)
            .. "\n\nThis cannot be undone.",
        ok_text = "Delete",
        ok_callback = function()
            if os.remove(full) then
                -- Also remove its reading data and history entry
                pcall(function() require("docsettings"):open(full):purge() end)
                pcall(function()
                    local history = require("readhistory")
                    if history.fileDeleted then
                        history:fileDeleted(full)
                    elseif history.removeItemByPath then
                        history:removeItemByPath(full)
                    end
                end)
            else
                UIManager:show(InfoMessage:new{ text = "Could not delete the file." })
            end
            self.files_state[p.id] = nil
            self.refresh(self:rectOf(win, 0))
            if self.on_library_changed then self.on_library_changed() end
        end,
    })
end

function Popups:paint(bb, ox, oy)
    local s = self.s
    for i, p in ipairs(self.list) do
        local win = self.wins[i]
        win:paint(bb, ox, oy)
        local draw = DRAW[p.kind]
        if draw then draw(self, bb, ox, oy, p, win) end
        -- Flip the content box: black ink on white paper becomes white on black
        bb:invertRect(ox + win.cx * s, oy + win.cy * s, win.cw * s, win.ch * s)
        local post = POST[p.kind]
        if post then post(self, bb, ox, oy, p, win) end
        -- Dotted outline on the window that is being moved
        if self.moving == i then
            local function dots(x, y, w, h)
                Dither.fill(bb, ox + x * s, oy + y * s, w * s, h * s, 0.5, s)
            end
            dots(win.x - 2, win.y - 2, win.w + 4, 2)
            dots(win.x - 2, win.y + win.h, win.w + 4, 2)
            dots(win.x - 2, win.y, 2, win.h)
            dots(win.x + win.w, win.y, 2, win.h)
        end
    end
end

-- Called every minute: refreshes clock windows and the battery window only
-- when its value actually changed (avoids a pointless e-ink refresh).
function Popups:refreshLive()
    local info = self.get_info and self.get_info()
    local batt_key = info and (tostring(info.batt) .. "|" .. tostring(info.charging)) or ""
    for i, p in ipairs(self.list) do
        if p.kind == "clock" then
            self.refresh(self:rectOf(self.wins[i], 0))
        elseif p.kind == "battery" and self.last_batt_key ~= batt_key then
            self.refresh(self:rectOf(self.wins[i], 0))
        end
    end
    self.last_batt_key = batt_key
end

-- ------------------------------------------------------------ interaction

-- Returns handled, region (screen pixels to refresh, if any).
function Popups:onTap(pos)
    if self.moving then
        self:dropMoving(pos)
        return true
    end
    for i = #self.list, 1, -1 do
        local p, win = self.list[i], self.wins[i]
        if inside(self:pxRect(win.x, win.y, win.w, win.h), pos) then
            local cr = win.close_rect
            local closes = inside(self:pxRect(cr.x, cr.y, cr.w, cr.h), pos)
            if not closes and (p.kind == "alert" or p.kind == "loading") then
                local b = self:alertButton(win)
                closes = inside(self:pxRect(b.x, b.y, b.w, b.h), pos)
            end
            if closes then
                local region = self:rectOf(win, 3)
                table.remove(self.list, i)
                self:rebuild()
                self:save()
                return true, region
            end
            if p.kind == "files" then
                self:filesTap(p, win, pos)
            elseif p.kind == "todo" then
                self:todoTap(p, win, pos)
            elseif p.kind == "image" then
                self:pickImage(p)
            elseif TAP_EDIT[p.kind] then
                self:editText(p)
            end
            return true  -- a popup swallows taps on its body
        end
    end
    return false
end

function Popups:onHold(pos)
    if self.moving then
        local win = self.wins[self.moving]
        self.moving = nil
        if win then self.refresh(self:rectOf(win, 3)) end
        return true
    end
    for i = #self.list, 1, -1 do
        local p, win = self.list[i], self.wins[i]
        if inside(self:pxRect(win.x, win.y, win.w, win.h), pos) then
            -- Hold on a file or folder of the explorer: its own actions
            if p.kind == "files" and self:filesHold(p, win, pos) then return true end
            if p.kind == "todo" and self:todoHold(p, win, pos) then return true end
            self:showPopupMenu(p)
            return true
        end
    end
    self:showNewMenu(pos)
    return true
end

function Popups:showNewMenu(pos)
    local rows = {}
    for _, cat in ipairs(CATEGORIES) do
        rows[#rows + 1] = { { cat[1], function() self:showKindMenu(cat, pos) end } }
    end
    rows[#rows + 1] = { { "Cancel", function() end } }
    showButtons("New window", rows)
end

function Popups:showKindMenu(cat, pos)
    local rows, row = {}, {}
    for _, kind in ipairs(cat[2]) do
        row[#row + 1] = { KINDS[kind].name, function() self:showSizeMenu(kind, pos) end }
        if #row == 2 then
            rows[#rows + 1] = row
            row = {}
        end
    end
    if #row > 0 then rows[#rows + 1] = row end
    rows[#rows + 1] = { { "Back", function() self:showNewMenu(pos) end } }
    showButtons(cat[1], rows)
end

function Popups:showSizeMenu(kind, pos)
    local sizes = KINDS[kind].sizes
    showButtons(KINDS[kind].name .. " - size", {
        {
            { "Small", function() self:create(kind, sizes[1], pos) end },
            { "Medium", function() self:create(kind, sizes[2], pos) end },
            { "Large", function() self:create(kind, sizes[3], pos) end },
        },
        { { "Cancel", function() end } },
    })
end

function Popups:create(kind, size, pos)
    local s = self.s
    local w, h = size[1], size[2]
    local p = {
        id = self.next_id, kind = kind, w = w, h = h, text = DEFAULT_TEXT[kind] or "",
        value = (kind == "loading") and 65 or nil,
        items = (kind == "todo") and {} or nil,
        x = snap((pos.x - self.ox) / s - w / 2),
        y = snap((pos.y - self.oy) / s - h / 2),
    }
    self.next_id = self.next_id + 1
    table.insert(self.list, p)
    self:rebuild()
    self:save()
    self.refresh(self:rectOf(self.wins[#self.wins], 3))
    if OPEN_EDITOR[kind] then self:editText(p) end
    if kind == "image" then self:pickImage(p) end
end

function Popups:showPopupMenu(p)
    local row2 = { { "Bring to front", function() self:bringToFront(p) end } }
    if MENU_EDIT[p.kind] then
        row2[#row2 + 1] = { "Edit text", function() self:editText(p) end }
    end
    local rows = {
        { { "Move", function() self:startMove(p) end },
          { "Resize", function() self:showResizeMenu(p) end } },
        row2,
    }
    if p.kind == "image" then
        rows[#rows + 1] = { { "Choose image", function() self:pickImage(p) end } }
    elseif p.kind == "todo" then
        rows[#rows + 1] = {
            { "Add task", function() self:addTask(p) end },
            { "Clear completed", function() self:clearDone(p) end },
        }
    end
    rows[#rows + 1] = { { "Close window", function() self:remove(p) end } }
    showButtons(KINDS[p.kind].name, rows)
end

function Popups:remove(p)
    local i = self:indexOf(p)
    if not i then return end
    local region = self:rectOf(self.wins[i], 3)
    table.remove(self.list, i)
    self:rebuild()
    self:save()
    self.refresh(region)
end

function Popups:bringToFront(p)
    local i = self:indexOf(p)
    if not i then return end
    table.remove(self.list, i)
    table.insert(self.list, p)
    self:rebuild()
    self:save()
    self.refresh(self:rectOf(self.wins[#self.wins], 3))
end

function Popups:startMove(p)
    local i = self:indexOf(p)
    if not i then return end
    self.moving = i
    self.refresh(self:rectOf(self.wins[i], 3))
    UIManager:show(InfoMessage:new{
        text = "Tap where the window should go.\nHold to cancel.", timeout = 2,
    })
end

function Popups:dropMoving(pos)
    local i = self.moving
    self.moving = nil
    local p, win = self.list[i], self.wins[i]
    if not p then return end
    local s = self.s
    local old = self:rectOf(win, 3)
    p.x = snap((pos.x - self.ox) / s - p.w / 2)
    p.y = snap((pos.y - self.oy) / s - p.h / 2)
    self:rebuild()
    self:save()
    self.refresh(old)
    self.refresh(self:rectOf(self.wins[i], 3))
end

function Popups:applySize(p, w, h)
    local i = self:indexOf(p)
    if not i then return end
    local old = self:rectOf(self.wins[i], 3)
    p.w, p.h = w, h
    self:rebuild()
    self:save()
    self.refresh(old)
    self.refresh(self:rectOf(self.wins[i], 3))
end

function Popups:showResizeMenu(p)
    local sizes = KINDS[p.kind].sizes
    local function preset(n)
        return function()
            self:applySize(p, sizes[n][1], sizes[n][2])
            self:showResizeMenu(p)
        end
    end
    local function step(dw, dh)
        return function()
            self:applySize(p, p.w + dw, p.h + dh)
            self:showResizeMenu(p)
        end
    end
    showButtons(string.format("Resize (%dx%d)", p.w, p.h), {
        { { "Small", preset(1) }, { "Medium", preset(2) }, { "Large", preset(3) } },
        { { "Wider", step(STEP, 0) }, { "Narrower", step(-STEP, 0) } },
        { { "Taller", step(0, STEP) }, { "Shorter", step(0, -STEP) } },
        { { "Done", function() end } },
    })
end

function Popups:editText(p)
    local dlg
    dlg = InputDialog:new{
        title = KINDS[p.kind].name,
        input = p.text or "",
        allow_newline = true,
        buttons = { {
            { text = "Cancel", callback = function() UIManager:close(dlg) end },
            { text = "Save", callback = function()
                p.text = dlg:getInputText()
                UIManager:close(dlg)
                self:save()
                local i = self:indexOf(p)
                if i then self.refresh(self:rectOf(self.wins[i], 3)) end
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

return Popups