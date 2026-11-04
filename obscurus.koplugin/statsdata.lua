-- Data for the statistics page: KOReader's "Reading statistics" database
-- plus the reading history (which works even without that plugin).
-- A short-lived cache (CACHE_SECS) is shared between the popups and the
-- statistics window so that opening them back-to-back does not re-read
-- DocSettings for up to 300 books every time.
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local Books = require("books")
local lfs = require("libs/libkoreader-lfs")

local floor, min = math.floor, math.min

local CACHE_SECS = 60
local cache, cache_time, cache_light = nil, 0, true

local Data = {}

-- Runs a query and returns a list of rows (numbers converted when possible).
local function rows(conn, sql)
    local res = conn:exec(sql)
    local out = {}
    if not res or not res[1] then return out end
    for i = 1, #res[1] do
        local row = {}
        for c = 1, #res do
            local v = res[c][i]
            row[c] = tonumber(v) or v
        end
        out[#out + 1] = row
    end
    return out
end

function Data.load(light)
    local cache_now = os.time()
    -- Cached data is reused when fresh and either the caller does not need
    -- the extra "finished" count, or the cache already has it.
    if cache and (cache_now - cache_time) < CACHE_SECS
       and (light or not cache_light) then
        return cache
    end

    local now = os.date("*t")
    local noon = os.time{ year = now.year, month = now.month, day = now.day, hour = 12 }
    local d = {
        noon = noon, days = {}, hours = {}, top = {},
        total_secs = 0, total_pages = 0, books_tracked = 0,
        history_count = 0,
    }
    for h = 0, 23 do d.hours[h] = 0 end

    -- Reading history
    local files = Books.history()
    d.history_count = #files
    if not light then
        d.finished = 0
        for i = 1, min(#files, 300) do
            local ok, status = pcall(function()
                local summary = DocSettings:open(files[i]):readSetting("summary")
                return summary and summary.status
            end)
            if ok and status == "complete" then d.finished = d.finished + 1 end
        end
    end

    -- Statistics database
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(path, "mode") ~= "file" then
        d.no_stats = true
    else
        local conn
        local ok, err = pcall(function()
            local SQ3 = require("lua-ljsqlite3/init")
            conn = SQ3.open(path)
            if not conn then error("could not open statistics database") end
            local t = os.time()

            -- Reading per day (last ~13 months)
            for _, r in ipairs(rows(conn, string.format(
                "SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime'), "
                .. "SUM(duration), COUNT(*) FROM page_stat_data "
                .. "WHERE start_time >= %d GROUP BY 1", t - 600 * 86400))) do
                d.days[r[1]] = { secs = r[2] or 0, pages = r[3] or 0 }
            end

            -- Reading per hour of the day (last 30 days)
            for _, r in ipairs(rows(conn, string.format(
                "SELECT CAST(strftime('%%H', start_time, 'unixepoch', 'localtime') AS INTEGER), "
                .. "SUM(duration) FROM page_stat_data WHERE start_time >= %d GROUP BY 1",
                t - 30 * 86400))) do
                local h = floor(tonumber(r[1]) or -1)
                if h >= 0 and h <= 23 then d.hours[h] = r[2] or 0 end
            end

            -- Totals
            local tot = rows(conn,
                "SELECT IFNULL(SUM(duration), 0), COUNT(*), COUNT(DISTINCT id_book) "
                .. "FROM page_stat_data")[1]
            if tot then
                d.total_secs, d.total_pages, d.books_tracked = tot[1], tot[2], tot[3]
            end

            -- Most read books
            for _, r in ipairs(rows(conn,
                "SELECT b.title, SUM(p.duration) AS t FROM page_stat_data p "
                .. "JOIN book b ON b.id = p.id_book GROUP BY p.id_book "
                .. "ORDER BY t DESC LIMIT 5")) do
                d.top[#d.top + 1] = { title = tostring(r[1] or "?"), secs = r[2] or 0 }
            end
        end)
        -- Do not leave the SQLite handle open when any query raises an error.
        if conn then pcall(function() conn:close() end) end
        if not ok then
            d.no_stats = true
            d.error = tostring(err)
        end
    end

    -- Derived numbers
    local function day(i) return d.days[os.date("%Y-%m-%d", noon - i * 86400)] end
    local today = day(0)
    d.today_secs = today and today.secs or 0
    d.today_pages = today and today.pages or 0
    local week = 0
    for i = 0, 6 do
        local x = day(i)
        if x then week = week + x.secs end
    end
    d.week_secs = week
    d.avg7 = week / 7
    local streak = 0
    for i = (d.today_secs > 0) and 0 or 1, 379 do
        local x = day(i)
        if x and x.secs > 0 then streak = streak + 1 else break end
    end
    d.streak = streak
    -- Extra numbers for the statistics popups
    local yesterday = day(1)
    d.yesterday_secs = yesterday and yesterday.secs or 0
    d.yesterday_pages = yesterday and yesterday.pages or 0
    local week_pages = 0
    for i = 0, 6 do
        local x = day(i)
        if x then week_pages = week_pages + x.pages end
    end
    d.week_pages = week_pages
    local best, run = 0, 0
    for i = 379, 0, -1 do
        local x = day(i)
        if x and x.secs > 0 then
            run = run + 1
            best = math.max(best, run)
        else
            run = 0
        end
    end
    d.best_streak = best

    cache = d
    cache_time = cache_now
    cache_light = light and true or false
    return d
end

-- Count completed books in bounded batches. The statistics window schedules
-- these batches between UI updates, avoiding a long synchronous DocSettings scan.
function Data.countFinishedBatch(files, first, batch_size)
    local finished = 0
    local last = min(#files, 300, first + (batch_size or 8) - 1)
    for i = first, last do
        local ok, status = pcall(function()
            local summary = DocSettings:open(files[i]):readSetting("summary")
            return summary and summary.status
        end)
        if ok and status == "complete" then finished = finished + 1 end
    end
    return finished, last + 1
end

function Data.setFinishedCount(count)
    if cache then
        cache.finished = count
        cache_light = false
    end
end

return Data