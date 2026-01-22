-- BG-GearScore Minimap Button
-- Simple minimap icon without external library dependencies

local addonName, addon = ...

local minimapButton = nil
local isDragging = false
local isSyncing = false
local syncSpinAngle = 0

-- Create the minimap button
function addon:CreateMinimapButton()
    if minimapButton then return end

    -- Create button frame
    local button = CreateFrame("Button", "BGGearScoreMinimapButton", Minimap)
    button:SetSize(32, 32)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:EnableMouse(true)
    button:SetMovable(true)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")

    -- Button textures
    local overlay = button:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetPoint("TOPLEFT")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetTexture("Interface\\Icons\\INV_Misc_Gear_01")
    background:SetPoint("CENTER", 0, 0)
    button.background = background

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetSize(24, 24)
    highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    highlight:SetBlendMode("ADD")
    highlight:SetPoint("CENTER", 0, 0)

    -- Sync indicator (spinning arrows overlay)
    local syncIndicator = button:CreateTexture(nil, "OVERLAY")
    syncIndicator:SetSize(20, 20)
    syncIndicator:SetTexture("Interface\\COMMON\\StreamCircle")  -- Circular arrows texture
    syncIndicator:SetPoint("CENTER", 0, 0)
    syncIndicator:SetVertexColor(0.2, 0.8, 1, 0.9)  -- Blue tint
    syncIndicator:Hide()
    button.syncIndicator = syncIndicator

    -- Click handler
    button:SetScript("OnClick", function(self, btn)
        if btn == "LeftButton" then
            if addon:IsInBattleground() then
                addon:ToggleScoreboard()
            else
                addon:ToggleHistory()
            end
        elseif btn == "RightButton" then
            addon:ToggleHistory()
        end
    end)

    -- Tooltip
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:ClearLines()
        GameTooltip:AddLine("BG-GearScore", 0, 0.8, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cFFFFFF00Left-click:|r Toggle scoreboard/history", 1, 1, 1)
        GameTooltip:AddLine("|cFFFFFF00Right-click:|r Open history", 1, 1, 1)
        GameTooltip:AddLine("|cFFFFFF00Drag:|r Move button", 1, 1, 1)
        GameTooltip:Show()
    end)

    button:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)

    -- Dragging for repositioning
    button:SetScript("OnDragStart", function(self)
        isDragging = true
        self:SetScript("OnUpdate", function(self)
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            px, py = px / scale, py / scale
            local angle = math.atan2(py - my, px - mx)
            addon:SetMinimapButtonPosition(angle)
        end)
    end)

    button:SetScript("OnDragStop", function(self)
        isDragging = false
        self:SetScript("OnUpdate", nil)
    end)

    minimapButton = button

    -- Set initial position
    local angle = addon.db and addon.db.settings.minimapButtonAngle or 225
    self:SetMinimapButtonPosition(math.rad(angle))

    -- Show/hide based on setting
    if addon.db and addon.db.settings.showMinimapButton then
        button:Show()
    else
        button:Hide()
    end

    return button
end

-- Position the button around the minimap
function addon:SetMinimapButtonPosition(angle)
    if not minimapButton then return end

    local radius = 80
    local x = math.cos(angle) * radius
    local y = math.sin(angle) * radius

    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)

    -- Save angle in degrees
    if addon.db and addon.db.settings then
        addon.db.settings.minimapButtonAngle = math.deg(angle)
    end
end

-- Show/hide the minimap button
function addon:ShowMinimapButton()
    if minimapButton then
        minimapButton:Show()
        if addon.db and addon.db.settings then
            addon.db.settings.showMinimapButton = true
        end
    end
end

function addon:HideMinimapButton()
    if minimapButton then
        minimapButton:Hide()
        if addon.db and addon.db.settings then
            addon.db.settings.showMinimapButton = false
        end
    end
end

function addon:ToggleMinimapButton()
    if minimapButton and minimapButton:IsShown() then
        self:HideMinimapButton()
        addon:Print("Minimap button hidden. Type /bggs minimap to show it again.")
    else
        self:ShowMinimapButton()
    end
end

-- Start sync animation on minimap button
function addon:StartMinimapSyncAnimation()
    if not minimapButton or not minimapButton.syncIndicator then return end
    if isSyncing then return end

    isSyncing = true
    syncSpinAngle = 0
    minimapButton.syncIndicator:Show()

    -- Spin animation
    minimapButton:SetScript("OnUpdate", function(self, elapsed)
        if not isSyncing then return end
        if isDragging then return end  -- Don't animate while dragging

        syncSpinAngle = syncSpinAngle + elapsed * 180  -- 180 degrees per second
        if syncSpinAngle >= 360 then
            syncSpinAngle = syncSpinAngle - 360
        end

        -- Rotate the sync indicator
        local rad = math.rad(syncSpinAngle)
        minimapButton.syncIndicator:SetRotation(rad)
    end)
end

-- Stop sync animation on minimap button
function addon:StopMinimapSyncAnimation()
    if not minimapButton or not minimapButton.syncIndicator then return end

    isSyncing = false
    minimapButton.syncIndicator:Hide()

    -- Remove OnUpdate unless we're dragging
    if not isDragging then
        minimapButton:SetScript("OnUpdate", nil)
    end
end

-- Initialize on addon load
function addon:InitializeMinimapButton()
    self:CreateMinimapButton()

    -- Register for sync callbacks to animate minimap button
    if addon.RegisterSyncCallback then
        addon:RegisterSyncCallback(function(eventType, data)
            if eventType == "SYNC_STARTED" then
                addon:StartMinimapSyncAnimation()
            elseif eventType == "SYNC_COMPLETE" or eventType == "SYNC_ERROR" then
                addon:StopMinimapSyncAnimation()
            end
        end)
    end
end
