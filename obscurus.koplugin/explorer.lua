-- File explorer window. Same size as the statistics window: a closable window
-- holding small card-windows (circle on the left) with the book covers.
local Blitbuffer = require("ffi/blitbuffer")
local Books = require("books")
local Covers = require("covers")
local Device = require("device")
local Dither = require("dither")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Settings = require("dotdash_settings")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Window = require("window")
local lfs = require("libs/libkoreader-lfs")

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min

local SIDE = 8                       -- same as the statistics window
local CARD_W, CARD_H, CARD_GAP = 48, 76, 5
local CV_W, CV_H = 40, 56            -- cover size inside a card
local STRIP = 7                      -- card title strip height
local TOOLBAR_H, FOOTER_H = 14, 12
local PATH_KEY = "dotdash_explorer_path"

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

local function clamp(v, lo, hi) return max(lo, min(hi, v)) end

local function inside(r, pos)
    return pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local function joinPath(dir, name)
    if dir == "/" then return "/" .. name end
    return dir .. "/" .. name
end

-- Same size as the statistics window (keep in sync with stats.lua)
local function windowSize(Wl, Hl)
    local chrome = Window.CHROME
    local base = 64 + 92 + 74 + 76 + 3 * 6 + 4
    local extra = max(0, min(40, Hl - 2 * 16 - chrome - base))
    return Wl - 2 * SIDE, min(base + extra + chrome, Hl - 8)
end

local function signature()
    local hidden = G_reader_settings:isTrue("show_hidden")
    local unsupported = G_reader_settings:isTrue("show_unsupported")
    return (hidden and "h" or "-") .. (unsupported and "u" or "-")
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

local Explorer = InputContainer:extend{
    name = "dotdash_explorer",
    scale = 1, ox = 0, oy = 0, canvas_w = 0, canvas_h = 0,
    reader_ui = nil,
    open_file = nil,
    on_library_changed = nil,
}

function Explorer:init()
    local s = self.scale
    self.s = s
    local W, H = Screen:getWidth(), Screen:getHeight()

    -- The window
    local w, h = windowSize(self.canvas_w, self.canvas_h)
    local win = Window.new(floor((self.canvas_w - w) / 2), floor((self.canvas_h - h) / 2),
        w, h, WHITE, s, true)
    self.win = win
    self.region = Geom:new{
        x = max(0, self.ox + win.x * s), y = max(0, self.oy + win.y * s),
        w = (win.w + Window.SHADOW) * s, h = (win.h + Window.SHADOW) * s,
    }
    self.dimen = self.region
    local cr = win.close_rect
    self.close_px = Geom:new{
        x = self.ox + cr.x * s, y = self.oy + cr.y * s, w = cr.w * s, h = cr.h * s,
    }

    -- Grid of cards
    self.cols = max(1, floor((win.cw - 6 + CARD_GAP) / (CARD_W + CARD_GAP)))
    local grid_w = self.cols * CARD_W + (self.cols - 1) * CARD_GAP
    self.grid_x = win.cx + floor((win.cw - grid_w) / 2)
    self.grid_y = win.cy + TOOLBAR_H + 3
    local avail = win.ch - TOOLBAR_H - 3 - FOOTER_H - 2
    self.rows = max(1, floor((avail + CARD_GAP) / (CARD_H + CARD_GAP)))
    self.per_page = self.cols * self.rows
    self.footer_y = win.cy + win.ch - FOOTER_H - 1

    -- Swallow every touch so the dashboard underneath does not react
    local full = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = full } },
        Swipe = { GestureRange:new{ ges = "swipe", range = full } },
        Hold = { GestureRange:new{ ges = "hold", range = full } },
    }

    self.queue = {}
    self.buttons = {}
    self.path = G_reader_settings:readSetting(PATH_KEY)
    self:load()
end

-- ---------------------------------------------------------------- helpers

function Explorer:face(mul) return monoFace(floor(mul * self.s)) end

function Explorer:mk(text, mul, max_w)
    return TextWidget:new{
        text = text, face = self:face(mul),
        max_width = max_w and (max_w * self.s) or nil,
    }
end

function Explorer:rect(bb, ox, oy, x, y, w, h, c)
    local s = self.s
    bb:paintRect(ox + x * s, oy + y * s, w * s, h * s, c)
end

-- Paints and frees a text widget at (x, y) dots, with horizontal alignment.
function Explorer:put(bb, ox, oy, tw, x, y, align)
    local s = self.s
    local size = tw:getSize()
    local px = ox + x * s
    if align == "center" then
        px = px - floor(size.w / 2)
    elseif align == "right" then
        px = px - size.w
    end
    tw:paintTo(bb, px, y)
    tw:free()
    return size.h
end

function Explorer:showMenu()
    local menu = self.reader_ui and self.reader_ui.menu
    if menu and menu.onShowMenu then pcall(menu.onShowMenu, menu) end
end

-- ----------------------------------------------------------------- listing

-- Start a folder scan. Only a small number of entries are inspected per
-- UIManager turn so large folders do not freeze touch input or drawing.
function Explorer:closeScanDir()
    local dir = self.scan_dir
    self.scan_dir = nil
    self.scan_iter = nil
    self.scan_control = nil
    pcall(function()
        if dir and dir.close then dir:close() end
    end)
end

function Explorer:load()
    local path = self.path
    if not path or lfs.attributes(path, "mode") ~= "directory" then
        path = Books.homeDir()
    end
    self.path = path
    if self.scan_task then UIManager:unschedule(self.scan_task) end
    if self.load_task then UIManager:unschedule(self.load_task) end
    if self.settings_check_task then UIManager:unschedule(self.settings_check_task) end
    self.settings_check_task = nil
    self:closeScanDir()
    self.scan_generation = (self.scan_generation or 0) + 1
    local generation = self.scan_generation
    self.queue = {}
    self.entries = {}
    self.page = 1
    self.scanning = true
    self.scan_finished = false
    self.sig = signature()
    self.scan_dirs, self.scan_files = {}, {}

    local ok, iter, dir = pcall(lfs.dir, path)
    if not ok or not iter then
        self.scanning = false
        self.scan_finished = true
        self.scan_task = nil
        self.scan_dirs, self.scan_files = nil, nil
        UIManager:setDirty(self, "ui", self.region)
        return
    end
    self.scan_iter, self.scan_dir, self.scan_control = iter, dir, nil
    self.scan_hidden = G_reader_settings:isTrue("show_hidden")
    self.scan_unsupported = G_reader_settings:isTrue("show_unsupported")
    self.scan_task = function() self:scanNext(generation) end
    UIManager:scheduleIn(0.03, self.scan_task)
    UIManager:setDirty(self, "ui", self.region)
end

function Explorer:scanNext(generation)
    -- A callback may already be queued when a scan is cancelled or completed.
    -- Ignore stale/duplicate callbacks instead of finalizing the same scan twice.
    if self.closed or self.suspended or generation ~= self.scan_generation
        or not self.scanning or self.scan_finished then
        return
    end
    if type(self.scan_iter) ~= "function" then
        self:finishScan(generation)
        return
    end
    local ok_registry, DocumentRegistry = pcall(require, "document/documentregistry")
    if not ok_registry or not DocumentRegistry then
        self:finishScan(generation)
        return
    end
    for _ = 1, 12 do
        local ok, name = pcall(self.scan_iter, self.scan_dir, self.scan_control)
        if not ok or name == nil then
            self:finishScan(generation)
            return
        end
        self.scan_control = name
        local hidden = name:sub(1, 1) == "."
        if name ~= "." and name ~= ".." and (self.scan_hidden or not hidden) then
            local full = joinPath(self.path, name)
            local attr_ok, mode = pcall(lfs.attributes, full, "mode")
            if attr_ok and mode == "directory" then
                if not name:match("%.sdr$") then
                    self.scan_dirs[#self.scan_dirs + 1] = {
                        name = name, full = full, dir = true, label = name,
                    }
                end
            elseif attr_ok and mode == "file" then
                local provider_ok, book = pcall(DocumentRegistry.hasProvider, DocumentRegistry, full)
                if (provider_ok and book) or self.scan_unsupported then
                    self.scan_files[#self.scan_files + 1] = {
                        name = name, full = full, book = provider_ok and book or false,
                        label = name:gsub("%.[^.]+$", ""),
                    }
                end
            end
        end
    end
    UIManager:scheduleIn(0.03, self.scan_task)
end

function Explorer:finishScan(generation)
    if self.closed or generation ~= self.scan_generation
        or not self.scanning or self.scan_finished then
        return
    end

    -- Mark completion before releasing scan state. If UIManager has another
    -- copy of this callback queued, scanNext()/finishScan() will now no-op.
    self.scan_finished = true
    self.scanning = false
    if self.scan_task then UIManager:unschedule(self.scan_task) end
    self.scan_task = nil
    self:closeScanDir()

    local dirs = type(self.scan_dirs) == "table" and self.scan_dirs or {}
    local files = type(self.scan_files) == "table" and self.scan_files or {}
    local function ci(a, b)
        return tostring(a.name or ""):lower() < tostring(b.name or ""):lower()
    end
    table.sort(dirs, ci)
    table.sort(files, ci)
    self.entries = {}
    for _, e in ipairs(dirs) do self.entries[#self.entries + 1] = e end
    for _, e in ipairs(files) do self.entries[#self.entries + 1] = e end
    self.scan_dirs, self.scan_files = nil, nil

    self:startLoading()
    UIManager:setDirty(self, "ui", self.region)
end

function Explorer:goTo(path)
    self.path = path
    G_reader_settings:saveSetting(PATH_KEY, path)
    self:load()
    UIManager:setDirty(self, "ui", self.region)
end

-- Covers are loaded one at a time so the window shows up right away.
function Explorer:cardPos(i)
    local col = (i - 1) % self.cols
    local row = floor((i - 1) / self.cols)
    return self.grid_x + col * (CARD_W + CARD_GAP), self.grid_y + row * (CARD_H + CARD_GAP)
end

function Explorer:startLoading()
    local s = self.s
    self.queue = {}
    local dither = Settings.ditherExplorer()
    local first = (self.page - 1) * self.per_page
    for i = 1, self.per_page do
        local e = self.entries[first + i]
        if not e then break end
        if e.book and not Covers.isLoaded(e.full, CV_W, CV_H, s, dither) then
            local x, y = self:cardPos(i)
            table.insert(self.queue, {
                file = e.full, dither = dither,
                region = Geom:new{
                    x = self.ox + x * s, y = self.oy + y * s,
                    w = (CARD_W + 2) * s, h = (CARD_H + 2) * s,
                },
            })
        end
    end
    if self.load_task then UIManager:unschedule(self.load_task) end
    self.load_task = function() self:loadNext() end
    UIManager:scheduleIn(0.2, self.load_task)
end

function Explorer:loadNext()
    if self.closed or self.suspended then return end
    local job = table.remove(self.queue, 1)
    if not job then self.load_task = nil return end
    Covers.load(job.file, CV_W, CV_H, self.s, job.dither)
    UIManager:setDirty(self, "ui", job.region)
    UIManager:scheduleIn(0.1, self.load_task)
end

-- ----------------------------------------------------------------- drawing

function Explorer:paintToolbar(bb, ox, oy)
    local s, win = self.s, self.win
    local y = win.cy + 1
    local bx = win.cx + 2
    self.buttons = {}

    local function button(id, label)
        local tw = self:mk(label, 4.5)
        local bw = ceil(tw:getSize().w / s) + 6
        self:rect(bb, ox, oy, bx, y, bw, 11, BLACK)
        self:rect(bb, ox, oy, bx + 1, y + 1, bw - 2, 9, WHITE)
        local th = tw:getSize().h
        self:put(bb, ox, oy, tw, bx + floor(bw / 2), oy + y * s + floor((11 * s - th) / 2), "center")
        self.buttons[#self.buttons + 1] = { id = id, x = bx, y = y, w = bw, h = 11 }
        bx = bx + bw + 3
    end

    local home = Books.homeDir()
    if self.path ~= "/" then button("up", "UP") end
    if self.path ~= home then button("home", "HOME") end

    -- Folder name (a * marks the home folder)
    local name = self.path:match("([^/]+)/?$") or "/"
    if self.path == home then name = name .. " *" end
    local tw = self:mk(name, 5, max(10, win.cx + win.cw - 2 - bx))
    local th = tw:getSize().h
    self:put(bb, ox, oy, tw, bx, oy + y * s + floor((11 * s - th) / 2), "left")

    Dither.fill(bb, ox + (win.cx + 2) * s, oy + (win.cy + TOOLBAR_H - 1) * s,
        (win.cw - 4) * s, s, 0.5, s)
end

function Explorer:paintFolder(bb, ox, oy, ax, ay)
    local s = self.s
    self:rect(bb, ox, oy, ax, ay + 8, 16, 7, BLACK)
    self:rect(bb, ox, oy, ax + 1, ay + 9, 14, 5, WHITE)
    self:rect(bb, ox, oy, ax, ay + 14, CV_W, 38, BLACK)
    Dither.fill(bb, ox + (ax + 1) * s, oy + (ay + 15) * s, (CV_W - 2) * s, 36 * s, 0.5, s)
end

-- A card drawn like a small window: shadow, frame, strip with a circle,
-- folder icon and the name. Drawn as black ink on white paper; the whole
-- content area is inverted afterwards (white frames on black).
function Explorer:paintCard(bb, ox, oy, x, y, e)
    local s = self.s
    Dither.fill(bb, ox + (x + 2) * s, oy + (y + 2) * s, CARD_W * s, CARD_H * s, 0.5, s)
    self:rect(bb, ox, oy, x, y, CARD_W, CARD_H, BLACK)
    self:rect(bb, ox, oy, x + 1, y + 1, CARD_W - 2, CARD_H - 2, WHITE)

    -- Circle (5x5) in the title strip
    self:rect(bb, ox, oy, x + 4, y + 1, 3, 1, BLACK)
    self:rect(bb, ox, oy, x + 3, y + 2, 1, 3, BLACK)
    self:rect(bb, ox, oy, x + 7, y + 2, 1, 3, BLACK)
    self:rect(bb, ox, oy, x + 4, y + 5, 3, 1, BLACK)

    local ax, ay = x + 4, y + STRIP + 1
    if e.dir then self:paintFolder(bb, ox, oy, ax, ay) end

    local tw = self:mk(e.label, 4, CARD_W - 4)
    self:put(bb, ox, oy, tw, x + floor(CARD_W / 2), oy + (ay + CV_H + 2) * s, "center")
end

-- Covers are drawn after the inversion, so they keep their normal look.
function Explorer:paintCover(bb, ox, oy, x, y, e)
    if e.dir then return end
    local s = self.s
    local cover = e.book
        and Covers.peek(e.full, CV_W, CV_H, s, Settings.ditherExplorer())
        or Covers.placeholder(CV_W, CV_H, s)
    bb:blitFrom(cover, ox + (x + 4) * s, oy + (y + STRIP + 1) * s, 0, 0, CV_W * s, CV_H * s)
end

function Explorer:paintFooter(bb, ox, oy)
    local s, win = self.s, self.win
    local pages = max(1, ceil(#self.entries / self.per_page))
    self.page = clamp(self.page, 1, pages)
    Dither.fill(bb, ox + (win.cx + 2) * s, oy + (self.footer_y - 1) * s,
        (win.cw - 4) * s, s, 0.5, s)
    local cx = win.cx + floor(win.cw / 2)
    local footer_text = self.scanning and "SCANNING..." or string.format("<  %d/%d  >", self.page, pages)
    local tw = self:mk(footer_text, 5)
    local th = tw:getSize().h
    self:put(bb, ox, oy, tw, cx, oy + self.footer_y * s + floor((FOOTER_H * s - th) / 2), "center")
    local count = self:mk(#self.entries .. " ITEMS", 4)
    local ch = count:getSize().h
    self:put(bb, ox, oy, count, win.cx + 2,
        oy + self.footer_y * s + floor((FOOTER_H * s - ch) / 2), "left")
end

function Explorer:paintTo(bb, x, y)
    -- Defensive fallback if a backend repaints before delivering SetDimensions.
    local landscape = Screen:getWidth() > Screen:getHeight()
    if landscape ~= self.suspended then
        self:onSetDimensions()
    end
    if self.suspended then return end
    local s = self.s
    local ox, oy = x + self.ox, y + self.oy
    -- Defer settings-triggered rescans until after drawing has returned.
    if self.sig ~= signature() and not self.settings_check_task then
        self.settings_check_task = function()
            self.settings_check_task = nil
            if not self.closed and not self.suspended and self.sig ~= signature() then self:load() end
        end
        UIManager:scheduleIn(0.01, self.settings_check_task)
    end
    self.win:paint(bb, ox, oy)
    self:paintToolbar(bb, ox, oy)
    self:paintFooter(bb, ox, oy)

    -- White frames and text on a black background (toolbar and footer)
    local win = self.win
    bb:invertRect(ox + win.cx * s, oy + win.cy * s, win.cw * s, win.ch * s)

    -- Cards on top, not inverted: white windows with a black frame
    local first = (self.page - 1) * self.per_page
    for i = 1, self.per_page do
        local e = self.entries[first + i]
        if not e then break end
        local cx, cy = self:cardPos(i)
        self:paintCard(bb, ox, oy, cx, cy, e)
        self:paintCover(bb, ox, oy, cx, cy, e)
    end
end

-- ------------------------------------------------------------ interaction

function Explorer:entryAt(lx, ly)
    local first = (self.page - 1) * self.per_page
    for i = 1, self.per_page do
        local e = self.entries[first + i]
        if not e then return nil end
        local x, y = self:cardPos(i)
        if lx >= x and lx < x + CARD_W and ly >= y and ly < y + CARD_H then return e end
    end
    return nil
end

function Explorer:setPage(page)
    local pages = max(1, ceil(#self.entries / self.per_page))
    page = clamp(page, 1, pages)
    if page == self.page then return end
    self.page = page
    self:startLoading()
    UIManager:setDirty(self, "ui", self.region)
end

function Explorer:openEntry(e)
    if e.dir then
        self:goTo(e.full)
    elseif e.book then
        UIManager:close(self)
        if self.open_file then self.open_file(e.full) end
    end
end

-- In landscape, use the current screen geometry directly instead of relying
-- on the portrait GestureRanges captured when this window was created.
function Explorer:onGesture(ges)
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
        return false
    end
    return InputContainer.onGesture(self, ges)
end

function Explorer:onTap(_, ges)
    local pos, s = ges.pos, self.s
    if self.suspended then
        if pos.y < Screen:getHeight() * 0.1 then
            self:showMenu()
            return true
        end
        return false
    end
    if inside(self.close_px, pos) then
        UIManager:close(self)
        return true
    end
    if pos.y < Screen:getHeight() * 0.1 then
        self:showMenu()
        return true
    end
    local lx, ly = (pos.x - self.ox) / s, (pos.y - self.oy) / s

    -- Toolbar buttons
    for _, b in ipairs(self.buttons) do
        if lx >= b.x and lx < b.x + b.w and ly >= b.y and ly < b.y + b.h then
            if b.id == "up" then
                self:goTo(self.path:match("^(.+)/[^/]+$") or "/")
            elseif b.id == "home" then
                self:goTo(Books.homeDir())
            end
            return true
        end
    end
    -- Page arrows
    if ly >= self.footer_y and ly < self.footer_y + FOOTER_H then
        local mid = self.win.cx + self.win.cw / 2
        self:setPage(self.page + (lx < mid and -1 or 1))
        return true
    end
    -- Cards
    local e = self:entryAt(lx, ly)
    if e then self:openEntry(e) end
    return true
end

function Explorer:onSwipe(_, ges)
    if ges.direction == "south" and ges.pos.y < Screen:getHeight() * 0.15 then
        self:showMenu()
        return true
    end
    return not self.suspended
end

function Explorer:onHold(_, ges)
    if self.suspended then return false end
    local s = self.s
    local e = self:entryAt((ges.pos.x - self.ox) / s, (ges.pos.y - self.oy) / s)
    if e then self:showActions(e) end
    return true
end

function Explorer:showActions(e)
    local home_target = e.dir and e.full or self.path
    local rows = {}
    if e.dir or e.book then
        rows[#rows + 1] = { { "Open", function() self:openEntry(e) end } }
    end
    rows[#rows + 1] = {
        { e.dir and "Set as home folder" or "Set this folder as home",
          function() self:setHome(home_target) end },
    }
    rows[#rows + 1] = {
        { e.dir and "Delete folder" or "Delete file", function() self:confirmDelete(e) end },
    }
    rows[#rows + 1] = { { "Cancel", function() end } }
    showButtons(e.label, rows)
end

function Explorer:setHome(path)
    G_reader_settings:saveSetting("home_dir", path)
    G_reader_settings:flush()
    UIManager:show(InfoMessage:new{ text = "Home folder:\n" .. path, timeout = 2 })
    self:load()
    UIManager:setDirty(self, "ui", self.region)
    if self.on_library_changed then self.on_library_changed() end
end

function Explorer:confirmDelete(e)
    local ConfirmBox = require("ui/widget/confirmbox")
    local what = e.dir and "folder and everything inside it" or "file"
    UIManager:show(ConfirmBox:new{
        text = "Delete this " .. what .. "?\n\n" .. e.name .. "\n\nThis cannot be undone.",
        ok_text = "Delete",
        ok_callback = function()
            local ok
            if e.dir then
                pcall(function() require("ffi/util").purgeDir(e.full) end)
                ok = lfs.attributes(e.full, "mode") == nil
            else
                ok = os.remove(e.full) and true or false
                if ok then pcall(function() require("docsettings"):open(e.full):purge() end) end
            end
                if ok then
                pcall(function()
                    local history = require("readhistory")
                    -- Prefer the O(1) removal for the deleted file; fall back
                    -- to the full scan only when the API is not available.
                    if history.fileDeleted then
                        history:fileDeleted(e.full)
                    elseif history.clearMissing then
                        history:clearMissing()
                    end
                end)
            else
                UIManager:show(InfoMessage:new{ text = "Could not delete it." })
            end
            self:load()
            UIManager:setDirty(self, "ui", self.region)
            if self.on_library_changed then self.on_library_changed() end
        end,
    })
end

function Explorer:onShow()
    if self.sig ~= signature() then self:load() end
    UIManager:setDirty(self, function() return "ui", self.region end)
end

function Explorer:onSetDimensions()
    local landscape = Screen:getWidth() > Screen:getHeight()
    if landscape == self.suspended then return end
    self.suspended = landscape
    -- Keep this widget as the input target; paintTo() skips its portrait UI.
    self.invisible = nil
    if landscape then
        if self.scan_task then UIManager:unschedule(self.scan_task) end
        if self.load_task then UIManager:unschedule(self.load_task) end
        if self.settings_check_task then UIManager:unschedule(self.settings_check_task) end
    else
        if self.scan_task and self.scanning then UIManager:scheduleIn(0.03, self.scan_task) end
        if self.load_task and #self.queue > 0 then UIManager:scheduleIn(0.1, self.load_task) end
        if self.settings_check_task then UIManager:scheduleIn(0.01, self.settings_check_task) end
    end
    -- Dashboard handles the full-stack repaint so KOReader can show the
    -- File Manager underneath while this window is suspended.
end

function Explorer:onCloseWidget()
    self.closed = true
    self.scan_generation = (self.scan_generation or 0) + 1
    if self.scan_task then UIManager:unschedule(self.scan_task) end
    if self.load_task then UIManager:unschedule(self.load_task) end
    if self.settings_check_task then UIManager:unschedule(self.settings_check_task) end
    self.settings_check_task = nil
    self:closeScanDir()
    -- Repaint what was under the window (the dashboard)
    UIManager:setDirty(nil, function() return "ui", self.region end)
end

return Explorer