local Settings = require("dotdash_settings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Device = require("device")
local Screen = Device.screen
local _ = require("gettext")

local plugin_path = debug.getinfo(1, "S").source:match("^@(.*)/main%.lua$")

-- The dashboard that is currently open (shared by every File Manager instance)
local open_dashboard = nil

local function isOpen()
    return open_dashboard ~= nil and UIManager:isWidgetShown(open_dashboard)
end

local DotDash = WidgetContainer:extend{
    name = "Obscurus",
    is_doc_only = false,
}

function DotDash:showDashboard()
    if isOpen() then return end
    -- Obscurus uses a portrait-only layout; defer creation in landscape.
    if Screen:getWidth() > Screen:getHeight() then
        self.waiting_for_portrait = true
        return
    end
    self.waiting_for_portrait = false
    local Dashboard = require("dashboard")
    open_dashboard = Dashboard:new{
        plugin_path = plugin_path,
        reader_ui = self.ui,
        on_close = function() self:closeDashboard() end,
    }
    UIManager:show(open_dashboard)
end

function DotDash:closeDashboard()
    if isOpen() then UIManager:close(open_dashboard) end
    open_dashboard = nil
end

-- KOReader quits when the window stack is empty, so the dashboard must
-- leave together with the File Manager (Exit / Restart / opening a book).
function DotDash:onCloseWidget()
    if self.ui.document then return end
    if isOpen() and open_dashboard.reader_ui == self.ui then
        self:closeDashboard()
    end
end

function DotDash:setEnabled(enabled)
    Settings.set(Settings.KEY_ENABLED, enabled)
    if enabled then
        -- Never show the dashboard on top of an open document
        if self.ui.document then return end
        UIManager:nextTick(function() self:showDashboard() end)
    else
        self:closeDashboard()
    end
end

function DotDash:toggleDither(key)
    Settings.set(key, not Settings.isOn(key))
    if isOpen() then open_dashboard:refreshCovers() end
end

function DotDash:buildMenuEntry()
    return {
        text = _("Obscurus"),
        sub_item_table = {
            {
                text = _("Enable as home screen"),
                checked_func = Settings.enabled,
                callback = function() self:setEnabled(not Settings.enabled()) end,
            },
            {
                text = _("Dithered covers"),
                sub_item_table = {
                    {
                        text = _("Recent book"),
                        keep_menu_open = true,
                        checked_func = Settings.ditherRecent,
                        callback = function() self:toggleDither(Settings.KEY_RECENT) end,
                    },
                    {
                        text = _("Right bar"),
                        keep_menu_open = true,
                        checked_func = Settings.ditherBar,
                        callback = function() self:toggleDither(Settings.KEY_BAR) end,
                    },
                    {
                        text = _("Explorer"),
                        keep_menu_open = true,
                        checked_func = Settings.ditherExplorer,
                        callback = function() self:toggleDither(Settings.KEY_EXPLORER) end,
                    },
                },
            },
            {
                text = _("Remember library page"),
                keep_menu_open = true,
                checked_func = Settings.keepLibraryPage,
                callback = function()
                    Settings.set(Settings.KEY_KEEP_PAGE, not Settings.keepLibraryPage())
                end,
            },
        },
    }
end

function DotDash:addMenuEntry()
    local menu = self.ui.menu
    if not menu then return end
    self.menu_entry = self:buildMenuEntry()
    local entry = self.menu_entry
    local function insert(m)
        local first = m.tab_item_table and m.tab_item_table[1]
        if first and first[1] ~= entry then table.insert(first, 1, entry) end
    end
    if menu.setUpdateItemTable then
        local original = menu.setUpdateItemTable
        menu.setUpdateItemTable = function(m, ...)
            local result = original(m, ...)
            insert(m)
            return result
        end
        insert(menu)
    else
        entry.sorting_hint = "filemanager"
        menu:registerToMainMenu(self)
    end
end

function DotDash:addToMainMenu(menu_items)
    menu_items.dotdash = self.menu_entry
end

function DotDash:init()
    if self.ui.document then return end
    self:addMenuEntry()
end

function DotDash:onShow()
    if self.ui.document or not Settings.enabled() then return end
    UIManager:nextTick(function() self:showDashboard() end)
end

-- If KOReader starts in landscape, wait until the screen returns to portrait.
function DotDash:onSetDimensions()
    if self.ui.document or not Settings.enabled() then return end
    if Screen:getWidth() <= Screen:getHeight()
        and self.waiting_for_portrait then
        UIManager:nextTick(function()
            if not self.ui.document and Settings.enabled() and not isOpen() then
                self:showDashboard()
            end
        end)
    elseif Screen:getWidth() > Screen:getHeight() then
        self.waiting_for_portrait = true
    end
end

return DotDash