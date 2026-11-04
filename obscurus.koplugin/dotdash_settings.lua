-- Plugin settings, stored in KOReader's global settings.
-- Every option is on unless it was explicitly switched off.
local Settings = {
    KEY_ENABLED = "dotdash_enabled",
    KEY_RECENT = "dotdash_dither_recent",   -- dithered cover of the recent book
    KEY_BAR = "dotdash_dither_bar",
    KEY_EXPLORER = "dotdash_dither_explorer",   -- dithered covers in the explorer         -- dithered covers of the right bar
    KEY_KEEP_PAGE = "dotdash_keep_library_page",
}

local function isOn(key)
    return G_reader_settings:readSetting(key) ~= false
end

Settings.isOn = isOn
function Settings.enabled() return isOn(Settings.KEY_ENABLED) end
function Settings.ditherRecent() return isOn(Settings.KEY_RECENT) end
function Settings.ditherBar() return isOn(Settings.KEY_BAR) end
function Settings.ditherExplorer() return isOn(Settings.KEY_EXPLORER) end
function Settings.keepLibraryPage() return isOn(Settings.KEY_KEEP_PAGE) end

function Settings.set(key, value)
    G_reader_settings:saveSetting(key, value)
    G_reader_settings:flush()
end

return Settings