-- BG-GearScore Scoreboard Frame
-- Live GearScore display during battlegrounds

local addonName, addon = ...

-- Frame dimensions
local FRAME_WIDTH = 220
local FRAME_HEIGHT = 420
local ROW_HEIGHT = 18
local MAX_VISIBLE_ROWS = 15
local HEADER_HEIGHT = 109  -- Increased to fit enemy rating line

-- Main scoreboard frame
local scoreboardFrame = nil
local playerRows = {}
local isShowing = false

-- Initialize the scoreboard
function addon:InitializeScoreboard()
    scoreboardFrame = self:CreateScoreboardFrame()
    addon:Debug("Scoreboard initialized")
end

-- Create the main scoreboard frame
function addon:CreateScoreboardFrame()
    local frame = CreateFrame("Frame", "BGGearScoreScoreboard", UIParent, "BackdropTemplate")
    frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    frame:SetPoint("RIGHT", UIParent, "RIGHT", -50, 0)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()

    -- Backdrop
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    frame:SetBackdropColor(0, 0, 0, 0.85)

    -- Title bar
    local titleBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    titleBar:SetSize(FRAME_WIDTH - 8, 24)
    titleBar:SetPoint("TOP", 0, -4)
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
    title:SetText("BG GearScore")
    frame.title = title

    -- Close button
    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function()
        addon:HideScoreboard()
    end)

    -- Team stats header - line 1 (GearScore)
    local gsStatsHeader = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gsStatsHeader:SetPoint("TOPLEFT", 12, -32)
    gsStatsHeader:SetWidth(FRAME_WIDTH - 24)
    gsStatsHeader:SetJustifyH("LEFT")
    frame.gsStatsHeader = gsStatsHeader

    -- Team stats header - line 2 (Level)
    local lvlStatsHeader = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lvlStatsHeader:SetPoint("TOPLEFT", 12, -46)
    lvlStatsHeader:SetWidth(FRAME_WIDTH - 24)
    lvlStatsHeader:SetJustifyH("LEFT")
    frame.lvlStatsHeader = lvlStatsHeader

    -- Team stats header - line 3 (Enemy Combat Rating)
    local enemyRatingHeader = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    enemyRatingHeader:SetPoint("TOPLEFT", 12, -60)
    enemyRatingHeader:SetWidth(FRAME_WIDTH - 24)
    enemyRatingHeader:SetJustifyH("LEFT")
    frame.enemyRatingHeader = enemyRatingHeader

    -- Win prediction display
    local predictionFrame = CreateFrame("Frame", nil, frame)
    predictionFrame:SetSize(FRAME_WIDTH - 24, 18)
    predictionFrame:SetPoint("TOPLEFT", 12, -74)

    -- Prediction text
    local predictionText = predictionFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    predictionText:SetPoint("LEFT", 0, 0)
    predictionText:SetJustifyH("LEFT")
    frame.predictionText = predictionText

    -- Prediction progress bar background
    local predictionBarBg = predictionFrame:CreateTexture(nil, "BACKGROUND")
    predictionBarBg:SetSize(80, 10)
    predictionBarBg:SetPoint("LEFT", 75, 0)
    predictionBarBg:SetColorTexture(0.2, 0.2, 0.2, 0.8)
    frame.predictionBarBg = predictionBarBg

    -- Prediction progress bar fill
    local predictionBar = predictionFrame:CreateTexture(nil, "ARTWORK")
    predictionBar:SetSize(1, 10)
    predictionBar:SetPoint("LEFT", predictionBarBg, "LEFT", 0, 0)
    predictionBar:SetColorTexture(0, 1, 0, 0.8)
    frame.predictionBar = predictionBar

    -- Column headers
    local headerY = -100
    local headers = {
        { text = "Player", x = 12, width = 120 },
        { text = "GS", x = 140, width = 50 },
    }

    for _, h in ipairs(headers) do
        local headerText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        headerText:SetPoint("TOPLEFT", h.x, headerY)
        headerText:SetWidth(h.width)
        headerText:SetJustifyH("LEFT")
        headerText:SetText(h.text)
        headerText:SetTextColor(0.8, 0.8, 0.2)
    end

    -- Scroll frame for player list
    local scrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 8, -HEADER_HEIGHT - 10)
    scrollFrame:SetPoint("BOTTOMRIGHT", -8, 40)

    -- Move scrollbar outside the frame
    local scrollBar = scrollFrame.ScrollBar or _G[scrollFrame:GetName().."ScrollBar"]
    if scrollBar then
        scrollBar:ClearAllPoints()
        scrollBar:SetPoint("TOPLEFT", scrollFrame, "TOPRIGHT", 2, -16)
        scrollBar:SetPoint("BOTTOMLEFT", scrollFrame, "BOTTOMRIGHT", 2, 16)
    end

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(FRAME_WIDTH - 36, MAX_VISIBLE_ROWS * ROW_HEIGHT)
    scrollFrame:SetScrollChild(scrollChild)
    frame.scrollChild = scrollChild

    -- Create player rows
    for i = 1, 40 do
        playerRows[i] = addon:CreatePlayerRow(scrollChild, i)
    end

    -- Bottom stats
    local queueStatus = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    queueStatus:SetPoint("BOTTOMLEFT", 12, 12)
    queueStatus:SetTextColor(0.6, 0.6, 0.6)
    frame.queueStatus = queueStatus

    -- History button
    local historyBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    historyBtn:SetSize(55, 20)
    historyBtn:SetPoint("BOTTOMRIGHT", -24, 8)
    historyBtn:SetText("History")
    historyBtn:SetScript("OnClick", function()
        addon:ToggleHistory()
    end)

    -- Scan button
    local scanBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    scanBtn:SetSize(55, 20)
    scanBtn:SetPoint("RIGHT", historyBtn, "LEFT", -4, 0)
    scanBtn:SetText("Rescan")
    scanBtn:SetScript("OnClick", function()
        addon:ForceScan()
    end)

    return frame
end

-- Create a single player row
function addon:CreatePlayerRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(FRAME_WIDTH - 40, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -((index - 1) * ROW_HEIGHT))
    row:Hide()

    -- Highlight on hover
    local highlight = row:CreateTexture(nil, "BACKGROUND")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.1)
    highlight:Hide()
    row.highlight = highlight

    row:EnableMouse(true)
    row:SetScript("OnEnter", function()
        highlight:Show()
    end)
    row:SetScript("OnLeave", function()
        highlight:Hide()
    end)

    -- Class icon
    local classIcon = row:CreateTexture(nil, "ARTWORK")
    classIcon:SetSize(14, 14)
    classIcon:SetPoint("LEFT", 0, 0)
    row.classIcon = classIcon

    -- Player name
    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameText:SetPoint("LEFT", classIcon, "RIGHT", 4, 0)
    nameText:SetWidth(100)
    nameText:SetJustifyH("LEFT")
    row.nameText = nameText

    -- GearScore
    local gsText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gsText:SetPoint("LEFT", 128, 0)
    gsText:SetWidth(55)
    gsText:SetJustifyH("RIGHT")
    row.gsText = gsText

    return row
end

-- Update the scoreboard UI
function addon:UpdateScoreboardUI()
    if not scoreboardFrame or not scoreboardFrame:IsShown() then return end

    -- Get friendly team data
    local friendlyPlayers = self:GetFriendlyPlayers()
    local teamStats = self:GetFriendlyTeamStats()
    local bgName = self:GetCurrentBG() or "Unknown BG"

    -- Update title
    scoreboardFrame.title:SetText(bgName)

    -- Update team stats headers
    local gsText = ""
    local lvlText = ""
    if teamStats then
        if teamStats.knownCount > 0 then
            gsText = string.format(
                "GS: |cFF%s%d|r avg / |cFF%s%d|r med  (%d/%d)",
                self:GetGearScoreColorHex(teamStats.avgGearScore),
                teamStats.avgGearScore,
                self:GetGearScoreColorHex(teamStats.medianGearScore),
                teamStats.medianGearScore,
                teamStats.knownCount,
                teamStats.totalCount
            )
            if teamStats.avgLevel and teamStats.avgLevel > 0 then
                lvlText = string.format(
                    "Lvl: %.1f avg / %d med",
                    teamStats.avgLevel,
                    teamStats.medianLevel or 0
                )
            end
        else
            gsText = string.format("Scanning... (0/%d)", teamStats.totalCount)
        end
    end
    scoreboardFrame.gsStatsHeader:SetText(gsText)
    scoreboardFrame.lvlStatsHeader:SetText(lvlText)

    -- Update combat rating display (shows both team's performance ratings)
    local friendlyRating = self:GetFriendlyCombatRating()
    local enemyRating = self:GetEnemyCombatRating()
    local isCalculating = self:IsCombatRatingCalculating()

    if isCalculating then
        scoreboardFrame.enemyRatingHeader:SetText("Combat: Calculating...")
        scoreboardFrame.enemyRatingHeader:SetTextColor(0.6, 0.6, 0.6)
    elseif friendlyRating and enemyRating then
        -- Show both ratings for comparison: "Combat: ~520 vs ~480"
        local friendlyColor = self:GetGearScoreColorHex(friendlyRating)
        local enemyColor = self:GetGearScoreColorHex(enemyRating)
        scoreboardFrame.enemyRatingHeader:SetText(string.format(
            "Combat: |cFF%s~%d|r vs |cFF%s~%d|r",
            friendlyColor, friendlyRating,
            enemyColor, enemyRating
        ))
    elseif enemyRating then
        -- Only enemy rating available (shouldn't happen normally)
        scoreboardFrame.enemyRatingHeader:SetText(string.format(
            "Enemy: |cFF%s~%d|r rating",
            self:GetGearScoreColorHex(enemyRating), enemyRating
        ))
    else
        scoreboardFrame.enemyRatingHeader:SetText("")
    end

    -- Update win prediction display
    local prediction, needsMore, matchesNeeded = self:GetCurrentPrediction()
    if needsMore then
        scoreboardFrame.predictionText:SetText(string.format("Need %d more matches", matchesNeeded))
        scoreboardFrame.predictionText:SetTextColor(0.6, 0.6, 0.6)
        scoreboardFrame.predictionBar:SetWidth(1)
        scoreboardFrame.predictionBarBg:Hide()
        scoreboardFrame.predictionBar:Hide()
    elseif prediction then
        local predColor = self:GetPredictionColor(prediction)
        scoreboardFrame.predictionText:SetText(string.format("Win: %d%%", prediction))
        scoreboardFrame.predictionText:SetTextColor(predColor.r, predColor.g, predColor.b)
        scoreboardFrame.predictionBarBg:Show()
        scoreboardFrame.predictionBar:Show()
        scoreboardFrame.predictionBar:SetWidth(math.max(1, prediction * 0.8))  -- Scale to 80px max
        scoreboardFrame.predictionBar:SetColorTexture(predColor.r, predColor.g, predColor.b, 0.8)
    else
        scoreboardFrame.predictionText:SetText("Scanning...")
        scoreboardFrame.predictionText:SetTextColor(0.6, 0.6, 0.6)
        scoreboardFrame.predictionBarBg:Hide()
        scoreboardFrame.predictionBar:Hide()
    end

    -- Update player rows
    for i = 1, 40 do
        local row = playerRows[i]
        local player = friendlyPlayers[i]

        if player then
            row:Show()

            -- Class icon
            if player.class then
                local coords = CLASS_ICON_TCOORDS[player.class:upper()]
                if coords then
                    row.classIcon:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
                    row.classIcon:SetTexCoord(unpack(coords))
                else
                    row.classIcon:SetTexture(nil)
                end
            else
                row.classIcon:SetTexture(nil)
            end

            -- Player name with class color
            local classColor = self:GetClassColor(player.class)
            local displayName = player.shortName or player.name
            if #displayName > 12 then
                displayName = displayName:sub(1, 11) .. "..."
            end
            row.nameText:SetText(displayName)
            row.nameText:SetTextColor(classColor.r, classColor.g, classColor.b)

            -- Highlight if this is the player
            local myName = UnitName("player")
            if player.name == myName or player.shortName == myName then
                row.nameText:SetText("> " .. displayName)
            end

            -- GearScore
            if player.gearScore and player.gearScore > 0 then
                local r, g, b = self:GetGearScoreColor(player.gearScore)
                row.gsText:SetText(tostring(player.gearScore))
                row.gsText:SetTextColor(r, g, b)
            else
                row.gsText:SetText("---")
                row.gsText:SetTextColor(0.5, 0.5, 0.5)
            end
        else
            row:Hide()
        end
    end

    -- Update scan status
    scoreboardFrame.queueStatus:SetText("Scan complete")
end

-- Abbreviate large numbers (e.g., 1234567 -> 1.2M)
function addon:AbbreviateNumber(num)
    if not num or num == 0 then return "0" end

    if num >= 1000000 then
        return string.format("%.1fM", num / 1000000)
    elseif num >= 1000 then
        return string.format("%.1fK", num / 1000)
    else
        return tostring(num)
    end
end

-- Show the scoreboard
function addon:ShowScoreboard()
    if scoreboardFrame then
        scoreboardFrame:Show()
        isShowing = true
        self:UpdateScoreboardUI()
    end
end

-- Hide the scoreboard
function addon:HideScoreboard()
    if scoreboardFrame then
        scoreboardFrame:Hide()
        isShowing = false
    end
end

-- Toggle scoreboard visibility
function addon:ToggleScoreboard()
    if isShowing then
        self:HideScoreboard()
    else
        if self:IsInBattleground() then
            self:ShowScoreboard()
        else
            addon:Print("Not in a battleground. Use /bggs history to view match history.")
        end
    end
end

-- Check if scoreboard is showing
function addon:IsScoreboardShowing()
    return isShowing
end

-- Class icon texture coordinates
CLASS_ICON_TCOORDS = {
    ["WARRIOR"] = {0, 0.25, 0, 0.25},
    ["MAGE"] = {0.25, 0.5, 0, 0.25},
    ["ROGUE"] = {0.5, 0.75, 0, 0.25},
    ["DRUID"] = {0.75, 1, 0, 0.25},
    ["HUNTER"] = {0, 0.25, 0.25, 0.5},
    ["SHAMAN"] = {0.25, 0.5, 0.25, 0.5},
    ["PRIEST"] = {0.5, 0.75, 0.25, 0.5},
    ["WARLOCK"] = {0.75, 1, 0.25, 0.5},
    ["PALADIN"] = {0, 0.25, 0.5, 0.75},
}

-- Get prediction color based on win chance
-- Green: >60%, Yellow: 40-60%, Red: <40%
function addon:GetPredictionColor(prediction)
    if prediction > 60 then
        return { r = 0, g = 1, b = 0 }  -- Green
    elseif prediction >= 40 then
        return { r = 1, g = 0.8, b = 0 }  -- Yellow
    else
        return { r = 1, g = 0.3, b = 0.3 }  -- Red
    end
end
