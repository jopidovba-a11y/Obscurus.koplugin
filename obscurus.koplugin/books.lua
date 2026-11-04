-- Book data sources: reading history, progress and title.
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local ReadHistory = require("readhistory")
local lfs = require("libs/libkoreader-lfs")

local Books = {}

-- True if the file is inside a hidden folder (a folder whose name starts with a dot).
local function inHiddenFolder(file)
    local dir = file:match("^(.*)/[^/]*$") or ""
    return dir:find("/%.[^/]") ~= nil
end

-- Existing files from the reading history, most recent first.
-- With skip_hidden, books inside hidden folders are left out.
function Books.history(skip_hidden)
    local list = {}
    for _, item in ipairs(ReadHistory.hist or {}) do
        if item.file and lfs.attributes(item.file, "mode") == "file"
            and not (skip_hidden and inHiddenFolder(item.file)) then
            table.insert(list, item.file)
        end
    end
    return list
end

function Books.progress(file)
    local ok, value = pcall(function()
        return DocSettings:open(file):readSetting("percent_finished")
    end)
    return (ok and tonumber(value)) or 0
end

function Books.title(file)
    local ok, props = pcall(function()
        return DocSettings:open(file):readSetting("doc_props")
    end)
    if ok and props and props.title and props.title ~= "" then
        return props.title
    end
    return file:match("([^/]+)%.[^.]+$") or file
end

-- KOReader's home folder, with a fallback when it is not set
function Books.homeDir()
    local d = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if d and lfs.attributes(d, "mode") == "directory" then
        return (d:gsub("(.)/+$", "%1"))
    end
    for _, c in ipairs({ "/mnt/onboard", "/sdcard", DataStorage:getDataDir() }) do
        if lfs.attributes(c, "mode") == "directory" then return c end
    end
    return "/"
end

-- Start a home-folder scan. The batch API lets UI callers yield between
-- small groups of files instead of freezing the interface on large folders.
function Books.beginHomeScan()
    local home = Books.homeDir()
    local state = {
        home = home, list = {}, recency = {}, done = false,
        iter = nil, dir = nil, control = nil,
    }
    for i, f in ipairs(Books.history()) do state.recency[f] = i end
    local ok, iter, dir = pcall(lfs.dir, home)
    if ok and iter then
        state.iter, state.dir = iter, dir
    else
        state.done = true
    end
    return state
end

function Books.closeHomeScan(state)
    if not state then return end
    local dir = state.dir
    state.dir = nil
    state.iter = nil
    state.control = nil
    state.done = true
    pcall(function()
        if dir and dir.close then dir:close() end
    end)
end

function Books.homeScanBatch(state, limit)
    if not state or state.done then return true, state and state.list or {} end
    local ok_registry, DocumentRegistry = pcall(require, "document/documentregistry")
    if not ok_registry or not DocumentRegistry then
        Books.closeHomeScan(state)
        return true, state.list
    end
    limit = math.max(1, tonumber(limit) or 16)
    for _ = 1, limit do
        local ok, name = pcall(state.iter, state.dir, state.control)
        if not ok or name == nil then
            state.done = true
            break
        end
        state.control = name
        if name:sub(1, 1) ~= "." then
            local full = (state.home == "/" and "" or state.home) .. "/" .. name
            local attr_ok, mode = pcall(lfs.attributes, full, "mode")
            if attr_ok and mode == "file" then
                local provider_ok, supported = pcall(DocumentRegistry.hasProvider, DocumentRegistry, full)
                if provider_ok and supported then
                    state.list[#state.list + 1] = full
                end
            end
        end
    end
    if state.done then
        table.sort(state.list, function(a, b)
            local ra, rb = state.recency[a], state.recency[b]
            if ra and rb then return ra < rb end
            if ra then return true end
            if rb then return false end
            return a:lower() < b:lower()
        end)
        Books.closeHomeScan(state)
    end
    return state.done, state.list
end

-- Synchronous compatibility wrapper. UI code should prefer the batch API.
function Books.homeBooks()
    local state = Books.beginHomeScan()
    while not state.done do Books.homeScanBatch(state, 256) end
    return state.list
end

return Books