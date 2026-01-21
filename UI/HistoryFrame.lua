-- BG-GearScore History Frame
-- Scrollable match history browser

local addonName, addon = ...

-- Frame dimensions
local FRAME_WIDTH = 450
local FRAME_HEIGHT = 500
local ROW_HEIGHT = 24
local MAX_VISIBLE_ROWS = 15

-- Main history frame
local historyFrame = nil
local matchRows = {}
local isShowing = false

-- Initialize the history browser
function addon:InitializeHistory()
    historyFrame = self:CreateHistoryFrame()
    addon:Debug("History browser initialized")
end

-- Create the main history frame
function addon:CreateHistoryFrame()
    local frame = CreateFrame("Frame", "BGGearScoreHistory", UIParent, "BackdropTemplate")
    frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    frame:SetFrameStrata("DIALOG")

    -- Backdrop
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 }
    })
    frame:SetBackdropColor(0, 0, 0, 0.9)

    -- Title bar
    local titleBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    titleBar:SetSize(FRAME_WIDTH - 12, 28)
    titleBar:SetPoint("TOP", 0, -6)
    titleBar:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    titleBar:SetBackdropColor(0.1, 0.1, 0.3, 0.9)

    -- Title text
    local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("CENTER")
    title:SetText("Match History")
    frame.title = title

    -- Close button
    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function()
        addon:HideHistory()
    end)

    -- Stats summary
    local statsFrame = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    statsFrame:SetSize(FRAME_WIDTH - 24, 50)
    statsFrame:SetPoint("TOP", 0, -40)
    statsFrame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    statsFrame:SetBackdropColor(0.05, 0.05, 0.1, 0.9)

    local statsText = statsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statsText:SetPoint("CENTER")
    statsText:SetWidth(FRAME_WIDTH - 40)
    frame.statsText = statsText

    -- Column headers
    local headerY = -100
    local headers = {
        { text = "Date", x = 16, width = 80 },
        { text = "Map", x = 100, width = 100 },
        { text = "Result", x = 205, width = 55 },
        { text = "Dur", x = 265, width = 40 },
        { text = "Team GS", x = 310, width = 60 },
        { text = "Team Lvl", x = 375, width = 55 },
    }

    for _, h in ipairs(headers) do
        local headerText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        headerText:SetPoint("TOPLEFT", h.x, headerY)
        headerText:SetWidth(h.width)
        headerText:SetJustifyH("LEFT")
        headerText:SetText(h.text)
        headerText:SetTextColor(0.8, 0.8, 0.2)
    end

    -- Scroll frame for match list
    local scrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 12, -120)
    scrollFrame:SetPoint("BOTTOMRIGHT", -32, 50)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(FRAME_WIDTH - 44, 100 * ROW_HEIGHT)
    scrollFrame:SetScrollChild(scrollChild)
    frame.scrollChild = scrollChild

    -- Create match rows
    for i = 1, 100 do
        matchRows[i] = addon:CreateMatchRow(scrollChild, i)
    end

    -- Clear history button
    local clearBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    clearBtn:SetSize(100, 22)
    clearBtn:SetPoint("BOTTOMLEFT", 16, 14)
    clearBtn:SetText("Clear History")
    clearBtn:SetScript("OnClick", function()
        StaticPopup_Show("BGGEARSCORE_CONFIRM_CLEAR")
    end)

    -- Refresh button
    local refreshBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    refreshBtn:SetSize(80, 22)
    refreshBtn:SetPoint("BOTTOMRIGHT", -28, 14)
    refreshBtn:SetText("Refresh")
    refreshBtn:SetScript("OnClick", function()
        addon:UpdateHistoryUI()
    end)

    -- Create confirmation dialog
    StaticPopupDialogs["BGGEARSCORE_CONFIRM_CLEAR"] = {
        text = "Are you sure you want to clear all match history?",
        button1 = "Yes",
        button2 = "No",
        OnAccept = function()
            addon:ClearHistory()
            addon:UpdateHistoryUI()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }

    return frame
end

-- Create a single match row
function addon:CreateMatchRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(FRAME_WIDTH - 56, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -((index - 1) * ROW_HEIGHT))
    row:Hide()

    -- Alternating background
    if index % 2 == 0 then
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, 0.03)
    end

    -- Highlight on hover
    local highlight = row:CreateTexture(nil, "BACKGROUND")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.1)
    highlight:Hide()
    row.highlight = highlight

    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        highlight:Show()
        addon:ShowMatchTooltip(self, index)
    end)
    row:SetScript("OnLeave", function()
        highlight:Hide()
        GameTooltip:Hide()
    end)

    -- Date
    local dateText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dateText:SetPoint("LEFT", 4, 0)
    dateText:SetWidth(80)
    dateText:SetJustifyH("LEFT")
    row.dateText = dateText

    -- Map name
    local mapText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mapText:SetPoint("LEFT", 88, 0)
    mapText:SetWidth(100)
    mapText:SetJustifyH("LEFT")
    row.mapText = mapText

    -- Result
    local resultText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    resultText:SetPoint("LEFT", 193, 0)
    resultText:SetWidth(55)
    resultText:SetJustifyH("CENTER")
    row.resultText = resultText

    -- Duration
    local durationText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    durationText:SetPoint("LEFT", 253, 0)
    durationText:SetWidth(40)
    durationText:SetJustifyH("CENTER")
    row.durationText = durationText

    -- Team GearScore
    local teamGsText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    teamGsText:SetPoint("LEFT", 298, 0)
    teamGsText:SetWidth(60)
    teamGsText:SetJustifyH("CENTER")
    row.teamGsText = teamGsText

    -- Team Level
    local teamLvlText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    teamLvlText:SetPoint("LEFT", 363, 0)
    teamLvlText:SetWidth(55)
    teamLvlText:SetJustifyH("CENTER")
    row.teamLvlText = teamLvlText

    return row
end

-- Update the history UI
function addon:UpdateHistoryUI()
    if not historyFrame or not historyFrame:IsShown() then return end

    local history = self:GetMatchHistory()
    local stats = self:GetStats()

    -- Update stats summary
    local winColor = stats.winRate >= 50 and "|cFF00FF00" or "|cFFFF6666"
    local predAccuracy = self:GetPredictionAccuracy()
    local predStr = ""
    if predAccuracy.totalPredictions > 0 then
        local predColor = predAccuracy.accuracy >= 50 and "|cFF00FF00" or "|cFFFF6666"
        predStr = string.format("  |  Pred Accuracy: %s%d%%|r", predColor, predAccuracy.accuracy)
    end
    local statsStr = string.format(
        "Total: %d  |  Wins: |cFF00FF00%d|r  Losses: |cFFFF4444%d|r  |  Win Rate: %s%d%%|r%s",
        stats.total,
        stats.wins,
        stats.losses,
        winColor,
        stats.winRate,
        predStr
    )
    historyFrame.statsText:SetText(statsStr)

    -- Update match rows
    for i = 1, 100 do
        local row = matchRows[i]
        local match = history[i]

        if match then
            row:Show()

            -- Date (short format)
            row.dateText:SetText(date("%m/%d %H:%M", match.timestamp))
            row.dateText:SetTextColor(0.7, 0.7, 0.7)

            -- Map name (abbreviated if needed)
            local mapName = match.mapName or "Unknown"
            if #mapName > 12 then
                mapName = mapName:sub(1, 10) .. ".."
            end
            row.mapText:SetText(mapName)
            row.mapText:SetTextColor(0.9, 0.9, 0.9)

            -- Result with color
            local result = match.result or "unknown"
            if result == "win" then
                row.resultText:SetText("Win")
                row.resultText:SetTextColor(0, 1, 0)
            elseif result == "loss" then
                row.resultText:SetText("Loss")
                row.resultText:SetTextColor(1, 0.3, 0.3)
            else
                row.resultText:SetText("Draw")
                row.resultText:SetTextColor(0.8, 0.8, 0.3)
            end

            -- Duration
            row.durationText:SetText(self:FormatDuration(match.duration))
            row.durationText:SetTextColor(0.7, 0.7, 0.7)

            -- Team GearScore (from friendly team)
            local teamGs = self:GetFriendlyTeamGsFromMatch(match)
            if teamGs and teamGs > 0 then
                local r, g, b = self:GetGearScoreColor(teamGs)
                row.teamGsText:SetText(tostring(teamGs))
                row.teamGsText:SetTextColor(r, g, b)
            else
                row.teamGsText:SetText("---")
                row.teamGsText:SetTextColor(0.5, 0.5, 0.5)
            end

            -- Team Level (from friendly team)
            local teamLvl = self:GetFriendlyTeamLvlFromMatch(match)
            if teamLvl and teamLvl > 0 then
                row.teamLvlText:SetText(string.format("%.1f", teamLvl))
                row.teamLvlText:SetTextColor(0.9, 0.9, 0.9)
            else
                row.teamLvlText:SetText("---")
                row.teamLvlText:SetTextColor(0.5, 0.5, 0.5)
            end
        else
            row:Hide()
        end
    end

    -- Adjust scroll child height
    historyFrame.scrollChild:SetHeight(math.max(#history * ROW_HEIGHT, FRAME_HEIGHT - 180))
end

-- Helper to get friendly team avg gear score from match data
function addon:GetFriendlyTeamGsFromMatch(match)
    if not match or not match.teams then return nil end
    -- Try both factions and return the one with data (we don't know player faction from history)
    for faction = 0, 1 do
        local team = match.teams[faction]
        if team and team.avgGearScore and team.avgGearScore > 0 then
            return team.avgGearScore
        end
    end
    return nil
end

-- Helper to get friendly team avg level from match data
function addon:GetFriendlyTeamLvlFromMatch(match)
    if not match or not match.teams then return nil end
    -- Try both factions and return the one with data (we don't know player faction from history)
    for faction = 0, 1 do
        local team = match.teams[faction]
        if team and team.avgLevel and team.avgLevel > 0 then
            return team.avgLevel
        end
    end
    return nil
end

-- Show detailed tooltip for a match
function addon:ShowMatchTooltip(row, index)
    local history = self:GetMatchHistory()
    local match = history[index]
    if not match then return end

    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()

    -- Header
    GameTooltip:AddLine(match.mapName or "Unknown Battleground", 1, 0.82, 0)
    GameTooltip:AddLine(self:FormatTimestamp(match.timestamp), 0.7, 0.7, 0.7)
    GameTooltip:AddLine(" ")

    -- Result
    local resultColor = match.result == "win" and {0, 1, 0}
        or match.result == "loss" and {1, 0.3, 0.3}
        or {0.8, 0.8, 0.3}
    local resultText = match.result == "win" and "Victory"
        or match.result == "loss" and "Defeat"
        or "Draw"
    GameTooltip:AddDoubleLine("Result:", resultText, 0.8, 0.8, 0.8, unpack(resultColor))

    -- Duration
    GameTooltip:AddDoubleLine("Duration:", self:FormatDuration(match.duration), 0.8, 0.8, 0.8, 0.9, 0.9, 0.9)

    -- Prediction vs Actual
    if match.prediction then
        local predColor = self:GetPredictionColor(match.prediction)
        local predictedWin = match.prediction > 50
        local actualWin = match.result == "win"
        local predCorrect = predictedWin == actualWin
        local correctStr = predCorrect and "|cFF00FF00Correct|r" or "|cFFFF4444Wrong|r"
        GameTooltip:AddDoubleLine(
            "Prediction:",
            string.format("%d%% - %s", match.prediction, correctStr),
            0.8, 0.8, 0.8,
            predColor.r, predColor.g, predColor.b
        )
    end

    -- Team stats if available
    if match.teams then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Team Stats:", 0.8, 0.8, 0.2)

        for faction, team in pairs(match.teams) do
            local factionName = faction == 0 and "Horde" or "Alliance"
            local factionColor = faction == 0 and {0.9, 0.3, 0.3} or {0.3, 0.5, 0.9}

            if team.avgGearScore and team.avgGearScore > 0 then
                local statsStr = string.format("GS: %d (med %d)", team.avgGearScore, team.medianGearScore or 0)
                if team.avgLevel and team.avgLevel > 0 then
                    statsStr = statsStr .. string.format("  Lvl: %.1f (med %d)", team.avgLevel, team.medianLevel or 0)
                end
                GameTooltip:AddDoubleLine(
                    factionName .. ":",
                    statsStr,
                    unpack(factionColor),
                    0.9, 0.9, 0.9
                )
                if team.knownCount and team.totalCount then
                    GameTooltip:AddDoubleLine(
                        "",
                        string.format("(%d/%d inspected)", team.knownCount, team.totalCount),
                        0, 0, 0,
                        0.6, 0.6, 0.6
                    )
                end
            end
        end
    end

    GameTooltip:Show()
end

-- Show the history browser
function addon:ShowHistory()
    if historyFrame then
        historyFrame:Show()
        isShowing = true
        self:UpdateHistoryUI()
    end
end

-- Hide the history browser
function addon:HideHistory()
    if historyFrame then
        historyFrame:Hide()
        isShowing = false
    end
end

-- Toggle history visibility
function addon:ToggleHistory()
    if isShowing then
        self:HideHistory()
    else
        self:ShowHistory()
    end
end

-- Check if history is showing
function addon:IsHistoryShowing()
    return isShowing
end
