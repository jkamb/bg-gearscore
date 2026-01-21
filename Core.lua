-- BG-GearScore Core
-- Main initialization, events, and slash commands

local addonName, addon = ...

-- Create main addon namespace
BGGearScore = addon
addon.version = "1.0.0"

-- Event frame for handling WoW events
local eventFrame = CreateFrame("Frame")
addon.eventFrame = eventFrame

-- Registered event handlers
local eventHandlers = {}

-- Register an event handler
function addon:RegisterEvent(event, handler)
    if not eventHandlers[event] then
        eventHandlers[event] = {}
        eventFrame:RegisterEvent(event)
    end
    table.insert(eventHandlers[event], handler)
end

-- Unregister an event handler
function addon:UnregisterEvent(event, handler)
    if eventHandlers[event] then
        for i, h in ipairs(eventHandlers[event]) do
            if h == handler then
                table.remove(eventHandlers[event], i)
                break
            end
        end
        if #eventHandlers[event] == 0 then
            eventFrame:UnregisterEvent(event)
            eventHandlers[event] = nil
        end
    end
end

-- Event dispatcher
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if eventHandlers[event] then
        for _, handler in ipairs(eventHandlers[event]) do
            handler(event, ...)
        end
    end
end)

-- Debug print function (uses persisted setting from db)
function addon:Debug(...)
    if self.db and self.db.settings and self.db.settings.debugMode then
        print("|cFF00FF00[BG-GS Debug]|r", ...)
    end
end

-- Print function for user messages
function addon:Print(...)
    print("|cFF00CCFFBGGearScore:|r", ...)
end

-- Initialization on ADDON_LOADED
local function OnAddonLoaded(event, loadedAddon)
    if loadedAddon ~= addonName then return end

    -- Initialize data store (will be set up in DataStore.lua)
    if addon.InitializeDataStore then
        addon:InitializeDataStore()
    end

    -- Initialize other modules
    if addon.InitializeInspectQueue then
        addon:InitializeInspectQueue()
    end

    if addon.InitializeBattlegroundTracker then
        addon:InitializeBattlegroundTracker()
    end

    if addon.InitializeScoreboard then
        addon:InitializeScoreboard()
    end

    if addon.InitializeHistory then
        addon:InitializeHistory()
    end

    if addon.InitializeMinimapButton then
        addon:InitializeMinimapButton()
    end

    addon:Print("Loaded v" .. addon.version .. " - Type /bggs for commands")
    addon:UnregisterEvent("ADDON_LOADED", OnAddonLoaded)
end

addon:RegisterEvent("ADDON_LOADED", OnAddonLoaded)

-- Slash command handler
local function HandleSlashCommand(msg)
    local cmd, arg = msg:match("^(%S*)%s*(.*)$")
    cmd = cmd:lower()

    if cmd == "" or cmd == "show" then
        -- Toggle scoreboard
        if addon.ToggleScoreboard then
            addon:ToggleScoreboard()
        else
            addon:Print("Scoreboard not available.")
        end
    elseif cmd == "history" then
        -- Open history browser
        if addon.ToggleHistory then
            addon:ToggleHistory()
        else
            addon:Print("History browser not available.")
        end
    elseif cmd == "scan" then
        -- Force rescan players
        if addon.ForceScan then
            addon:ForceScan()
            addon:Print("Rescanning players...")
        else
            addon:Print("Scanner not available.")
        end
    elseif cmd == "config" or cmd == "settings" then
        -- Show/toggle settings
        addon:Print("Settings:")
        addon:Print("  Auto-show in BG: " .. (addon.db and addon.db.settings.autoShowInBG and "ON" or "OFF"))
        addon:Print("  Debug mode: " .. (addon.db and addon.db.settings.debugMode and "ON" or "OFF"))
        addon:Print("  Max history entries: " .. (addon.db and addon.db.settings.maxHistoryEntries or 100))
        addon:Print("Use /bggs autoshow to toggle auto-show setting")
    elseif cmd == "autoshow" then
        -- Toggle auto-show setting
        if addon.db and addon.db.settings then
            addon.db.settings.autoShowInBG = not addon.db.settings.autoShowInBG
            addon:Print("Auto-show in BG: " .. (addon.db.settings.autoShowInBG and "ON" or "OFF"))
        end
    elseif cmd == "minimap" then
        -- Toggle minimap button
        if addon.ToggleMinimapButton then
            addon:ToggleMinimapButton()
        end
    elseif cmd == "clearcache" then
        -- Clear player cache
        if addon.db then
            addon.db.playerCache = {}
            addon:ClearSessionCache()
            addon:Print("Cache cleared. Your GearScore will be recalculated.")
        end
    elseif cmd == "myscore" then
        -- Show current player's GearScore calculation
        local gs, extra = addon:CalculateGearScore("player")
        addon:Print("Your GearScore: " .. (gs or "N/A"))
        if TT_GS and TT_GS.GetScore then
            local ttgs = TT_GS:GetScore("player")
            addon:Print("TacoTip GearScore: " .. (ttgs or "N/A"))
        end
    elseif cmd == "debug" then
        -- Toggle debug mode (persisted)
        if addon.db and addon.db.settings then
            addon.db.settings.debugMode = not addon.db.settings.debugMode
            addon:Print("Debug mode: " .. (addon.db.settings.debugMode and "ON" or "OFF"))
        end
    elseif cmd == "help" then
        addon:Print("Commands:")
        addon:Print("  /bggs - Toggle scoreboard")
        addon:Print("  /bggs history - Open match history")
        addon:Print("  /bggs scan - Rescan players")
        addon:Print("  /bggs config - Show settings")
        addon:Print("  /bggs autoshow - Toggle auto-show in BG")
        addon:Print("  /bggs minimap - Toggle minimap button")
        addon:Print("  /bggs debug - Toggle debug mode")
    else
        addon:Print("Unknown command. Type /bggs help for usage.")
    end
end

-- Register slash commands
SLASH_BGGEARSCORE1 = "/bggs"
SLASH_BGGEARSCORE2 = "/bggearscore"
SlashCmdList["BGGEARSCORE"] = HandleSlashCommand

-- Utility functions

-- Get player faction (0 = Horde, 1 = Alliance)
function addon:GetPlayerFaction()
    local faction = UnitFactionGroup("player")
    if faction == "Horde" then
        return 0
    elseif faction == "Alliance" then
        return 1
    end
    return nil
end

-- Check if we're in a battleground
function addon:IsInBattleground()
    local inInstance, instanceType = IsInInstance()
    return inInstance and instanceType == "pvp"
end

-- Get current battleground name
function addon:GetBattlegroundName()
    if self:IsInBattleground() then
        return GetInstanceInfo() or "Unknown Battleground"
    end
    return nil
end

-- Format number with commas
function addon:FormatNumber(num)
    if not num then return "0" end
    local formatted = tostring(math.floor(num))
    while true do
        formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return formatted
end

-- Get class color
local CLASS_COLORS = {
    WARRIOR = {r=0.78, g=0.61, b=0.43},
    PALADIN = {r=0.96, g=0.55, b=0.73},
    HUNTER = {r=0.67, g=0.83, b=0.45},
    ROGUE = {r=1.00, g=0.96, b=0.41},
    PRIEST = {r=1.00, g=1.00, b=1.00},
    SHAMAN = {r=0.00, g=0.44, b=0.87},
    MAGE = {r=0.41, g=0.80, b=0.94},
    WARLOCK = {r=0.58, g=0.51, b=0.79},
    DRUID = {r=1.00, g=0.49, b=0.04},
}

function addon:GetClassColor(class)
    if class and CLASS_COLORS[class:upper()] then
        return CLASS_COLORS[class:upper()]
    end
    return {r=1, g=1, b=1}
end

function addon:GetClassColorHex(class)
    local c = self:GetClassColor(class)
    return string.format("%02x%02x%02x", c.r*255, c.g*255, c.b*255)
end
