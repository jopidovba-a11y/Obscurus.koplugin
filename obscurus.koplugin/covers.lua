-- Loads book covers, either as dithered (dotted) bitmaps or as normal images.
-- The cache is LRU-bounded so scrolling through a large library does not
-- grow memory without limit.
local Blitbuffer = require("ffi/blitbuffer")
local Dither = require("dither")
local RenderImage = require("ui/renderimage")

local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local Covers = {}
local cache = {}           -- key -> BB, or false if no cover was found
local cache_order = {}     -- keys in LRU order (oldest first)
local placeholders = {}
local MAX_CACHE = 40       -- maximum number of covers kept in memory

local function safeFree(bb)
    if bb then pcall(function() bb:free() end) end
end

-- dither: true (default) for dotted covers, false for the normal image
local function keyOf(file, w, h, scale, dither)
    return file .. "|" .. w .. "x" .. h .. "@" .. scale .. ((dither ~= false) and "|d" or "|n")
end

-- Moves the key to the end of the LRU order.
local function touch(key)
    for i = 1, #cache_order do
        if cache_order[i] == key then
            table.remove(cache_order, i)
            break
        end
    end
    cache_order[#cache_order + 1] = key
end

-- Frees the oldest entries until the cache fits MAX_CACHE.
local function evict()
    while #cache_order > MAX_CACHE do
        local key = table.remove(cache_order, 1)
        local bb = cache[key]
        if bb then safeFree(bb) end
        cache[key] = nil
    end
end

local function frame(bb, w, h, s)
    bb:paintRect(0, 0, w * s, s, BLACK)
    bb:paintRect(0, (h - 1) * s, w * s, s, BLACK)
    bb:paintRect(0, 0, s, h * s, BLACK)
    bb:paintRect((w - 1) * s, 0, s, h * s, BLACK)
end

-- Raw cover: first from CoverBrowser's cache (shared, don't free), then by
-- opening the book (fresh BB, caller must free). Returns (bb, owned).
local function fetchRaw(file)
    local ok, BIM = pcall(require, "bookinfomanager")
    if ok and BIM then
        local ok2, info = pcall(function() return BIM:getBookInfo(file, true) end)
        if ok2 and info and info.cover_bb then return info.cover_bb, false end
    end
    local DocumentRegistry = require("document/documentregistry")
    local ok3, doc = pcall(function() return DocumentRegistry:openDocument(file) end)
    if ok3 and doc then
        local ok4, bb = pcall(function() return doc:getCoverPageImage() end)
        pcall(function() doc:close() end)
        if ok4 and bb then return bb, true end
        if bb then safeFree(bb) end
    end
    return nil, false
end

function Covers.placeholder(w, h, scale)
    local key = w .. "x" .. h .. "@" .. scale
    if placeholders[key] then return placeholders[key] end
    local out = Blitbuffer.new(w * scale, h * scale, Blitbuffer.TYPE_BB8)
    local ok, err = pcall(function()
        out:fill(BLACK)
        Dither.fill(out, scale, scale, (w - 2) * scale, (h - 2) * scale, 0.5, scale)
        frame(out, w, h, scale)
    end)
    if not ok then
        safeFree(out)
        error(err)
    end
    placeholders[key] = out
    return out
end

function Covers.isLoaded(file, w, h, scale, dither)
    return cache[keyOf(file, w, h, scale, dither)] ~= nil
end

function Covers.peek(file, w, h, scale, dither)
    local key = keyOf(file, w, h, scale, dither)
    local bb = cache[key]
    if bb then
        touch(key)   -- visible covers stay recent so they are not evicted
        return bb
    end
    return Covers.placeholder(w, h, scale)
end

function Covers.load(file, w, h, scale, dither)
    local key = keyOf(file, w, h, scale, dither)
    if cache[key] ~= nil then return end

    local raw, owned, small, out
    local ok, result = pcall(function()
        raw, owned = fetchRaw(file)
        if not raw then return false end

        if dither == false then
            out = RenderImage:scaleBlitBuffer(raw, w * scale, h * scale, true)
            if not out then return false end
            frame(out, w, h, scale)
        else
            small = RenderImage:scaleBlitBuffer(raw, w, h, true)
            if not small then return false end
            out = Blitbuffer.new(w * scale, h * scale, Blitbuffer.TYPE_BB8)
            if not out then return false end
            out:fill(BLACK)
            for y = 0, h - 1 do
                local run
                for x = 0, w do
                    local white = false
                    if x < w then
                        local a = small:getPixel(x, y):getColor8().a / 255
                        a = math.max(0, math.min(1, (a - 0.5) * 1.2 + 0.5))
                        white = a > (Dither.BAYER[(y % 4) * 4 + (x % 4) + 1] + 0.5) / 16
                    end
                    if white and not run then
                        run = x
                    elseif not white and run then
                        out:paintRect(run * scale, y * scale, (x - run) * scale, scale, WHITE)
                        run = nil
                    end
                end
            end
            frame(out, w, h, scale)
        end

        -- Transfer ownership to the cache only after the whole operation worked.
        local finished = out
        out = nil
        return finished
    end)

    -- Every temporary stays in an outer scope so errors cannot orphan it.
    safeFree(small)
    if owned then safeFree(raw) end
    if out then safeFree(out) end

    cache[key] = (ok and result) or false
    touch(key)
    evict()
end

-- Converts an already scaled image (w x h dots) into a dithered bitmap
function Covers.dither(small, w, h, scale)
    local out = Blitbuffer.new(w * scale, h * scale, Blitbuffer.TYPE_BB8)
    local ok, err = pcall(function()
        out:fill(BLACK)
        for y = 0, h - 1 do
            local run
            for x = 0, w do
                local white = false
                if x < w then
                    local a = small:getPixel(x, y):getColor8().a / 255
                    a = math.max(0, math.min(1, (a - 0.5) * 1.2 + 0.5))
                    white = a > (Dither.BAYER[(y % 4) * 4 + (x % 4) + 1] + 0.5) / 16
                end
                if white and not run then
                    run = x
                elseif not white and run then
                    out:paintRect(run * scale, y * scale, (x - run) * scale, scale, WHITE)
                    run = nil
                end
            end
        end
    end)
    if not ok then
        safeFree(out)
        error(err)
    end
    return out
end

function Covers.free()
    for _, bb in pairs(cache) do
        if bb then safeFree(bb) end
    end
    for _, bb in pairs(placeholders) do safeFree(bb) end
    cache, cache_order, placeholders = {}, {}, {}
end

return Covers