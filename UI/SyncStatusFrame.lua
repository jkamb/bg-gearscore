-- BG-GearScore Sync Status Frame
-- Displays guild sync progress and status

local addonName, addon = ...

local syncStatusFrame = nil
local hideTimer = nil
local AUTO_HIDE_DELAY = 5  -- Seconds after idle before hiding

-- Create the sync status frame
local function CreateSyncStatusFrame()
    if syncStatusFrame then return syncStatusFrame end

    -- Main frame
    local frame = CreateFrame("Frame", "BGGearScoreSyncStatus", UIParent, "BackdropTemplate")
    frame:SetSize(280, 60)
    frame:SetPoint("TOP", UIParent, "TOP", 0, -100)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)
    frame:SetFrameStrata("DIALOG")

    -- Backdrop
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 16,
        insets = {left = 4, right = 4, top = 4, bottom = 4},
    })
    frame:SetBackdropColor(0, 0, 0, 0.9)

    -- Drag handling
    frame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
    end)

    -- Title
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 12, -8)
    title:SetText("Guild Sync")
    title:SetTextColor(0.5, 0.8, 1)
    frame.title = title

    -- Status text
    local statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("TOPLEFT", 12, -22)
    statusText:SetWidth(256)
    statusText:SetJustifyH("LEFT")
    statusText:SetText("Initializing...")
    statusText:SetTextColor(1, 1, 1)
    frame.statusText = statusText

    -- Progress bar background
    local progressBg = frame:CreateTexture(nil, "ARTWORK")
    progressBg:SetPoint("TOPLEFT", 12, -38)
    progressBg:SetSize(256, 12)
    progressBg:SetColorTexture(0.1, 0.1, 0.1, 0.8)
    frame.progressBg = progressBg

    -- Progress bar fill
    local progressFill = frame:CreateTexture(nil, "OVERLAY")
    progressFill:SetPoint("TOPLEFT", progressBg, "TOPLEFT", 1, -1)
    progressFill:SetSize(0, 10)
    progressFill:SetColorTexture(0.2, 0.6, 1, 1)
    frame.progressFill = progressFill

    -- Progress text
    local progressText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    progressText:SetPoint("CENTER", progressBg, "CENTER", 0, 0)
    progressText:SetText("0%")
    frame.progressText = progressText

    -- Close button
    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", 4, 4)
    closeBtn:SetSize(20, 20)

    -- Manual sync button
    local syncBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    syncBtn:SetPoint("TOPRIGHT", -24, -4)
    syncBtn:SetSize(60, 18)
    syncBtn:SetText("Sync")
    syncBtn:SetScript("OnClick", function()
        if addon.RequestGuildSync then
            addon:RequestGuildSync(true)  -- Manual sync from UI button
        end
    end)
    frame.syncBtn = syncBtn

    frame:Hide()
    syncStatusFrame = frame

    return frame
end

-- Update progress display
local function UpdateProgress(progress, statusText)
    if not syncStatusFrame then return end

    local percent = math.floor(progress * 100)
    syncStatusFrame.progressText:SetText(percent .. "%")

    -- Animate progress bar width
    local maxWidth = 254  -- progressBg width - 2 for borders
    local targetWidth = maxWidth * progress
    syncStatusFrame.progressFill:SetWidth(math.max(1, targetWidth))

    if statusText then
        syncStatusFrame.statusText:SetText(statusText)
    end

    -- Color based on progress
    if progress >= 1 then
        syncStatusFrame.progressFill:SetColorTexture(0.2, 0.8, 0.2, 1)  -- Green
    else
        syncStatusFrame.progressFill:SetColorTexture(0.2, 0.6, 1, 1)  -- Blue
    end
end

-- Show the sync status frame
function addon:ShowSyncStatus(message, progress)
    if not syncStatusFrame then
        CreateSyncStatusFrame()
    end

    -- Cancel any pending hide (defensive check for timer object validity)
    if hideTimer then
        local success = pcall(function() hideTimer:Cancel() end)
        hideTimer = nil
    end

    syncStatusFrame:Show()

    if message then
        syncStatusFrame.statusText:SetText(message)
    end

    if progress then
        UpdateProgress(progress, message)
    end
end

-- Hide the sync status frame
function addon:HideSyncStatus()
    if syncStatusFrame then
        syncStatusFrame:Hide()
    end
end

-- Schedule auto-hide
local function ScheduleAutoHide()
    if hideTimer then
        hideTimer:Cancel()
    end
    hideTimer = C_Timer.NewTimer(AUTO_HIDE_DELAY, function()
        addon:HideSyncStatus()
        hideTimer = nil
    end)
end

-- Track if current sync is manual (for deciding whether to show popup)
local isCurrentSyncManual = false

-- Sync callback handler
local function OnSyncEvent(eventType, data)
    if eventType == "SYNC_STARTED" then
        isCurrentSyncManual = data.isManual or false
        -- Only show popup for manual sync
        if isCurrentSyncManual then
            addon:ShowSyncStatus("Starting sync...", 0)
        end

    elseif eventType == "SYNC_PROGRESS" then
        -- Only show popup for manual sync
        if isCurrentSyncManual then
            addon:ShowSyncStatus(data.status, data.progress)
        end

    elseif eventType == "SYNC_COMPLETE" then
        -- Only show popup for manual sync OR if new matches were found
        local wasManual = isCurrentSyncManual or data.isManual
        if wasManual or (data.newMatches and data.newMatches > 0) then
            local msg
            if data.newMatches > 0 then
                msg = string.format("Synced %d matches", data.newMatches)
                if data.conflicts > 0 then
                    msg = msg .. string.format(" (%d conflicts resolved)", data.conflicts)
                end
            else
                msg = "Up to date"
            end
            addon:ShowSyncStatus(msg, 1)
            ScheduleAutoHide()
        end
        isCurrentSyncManual = false

    elseif eventType == "SYNC_ERROR" then
        -- Only show errors for manual sync
        if isCurrentSyncManual then
            addon:ShowSyncStatus("Sync failed: " .. (data.reason or "Unknown error"), 0)
            if syncStatusFrame then
                syncStatusFrame.progressFill:SetColorTexture(0.8, 0.2, 0.2, 1)  -- Red
            end
            ScheduleAutoHide()
        end
        isCurrentSyncManual = false
    end
end

-- Initialize sync status UI
function addon:InitializeSyncStatus()
    -- Create frame (lazy, will be created on first show)
    -- Register for sync callbacks
    if addon.RegisterSyncCallback then
        addon:RegisterSyncCallback(OnSyncEvent)
    end

    addon:Debug("SyncStatus UI initialized")
end

-- Get sync status for tooltip/display
function addon:GetSyncStatusText()
    local status = self:GetSyncStatus and self:GetSyncStatus() or {}

    if not status.isInGuild then
        return "Not in a guild"
    end

    if status.state == "IDLE" then
        if status.lastSyncTime > 0 then
            local elapsed = time() - status.lastSyncTime
            if elapsed < 60 then
                return "Last sync: just now"
            elseif elapsed < 3600 then
                return string.format("Last sync: %d min ago", math.floor(elapsed / 60))
            else
                return string.format("Last sync: %d hours ago", math.floor(elapsed / 3600))
            end
        else
            return "Never synced"
        end
    else
        return "Syncing..."
    end
end

-- Toggle sync status frame visibility
function addon:ToggleSyncStatus()
    if not syncStatusFrame then
        CreateSyncStatusFrame()
    end

    if syncStatusFrame:IsShown() then
        syncStatusFrame:Hide()
    else
        -- Show with current status
        local status = self:GetSyncStatus and self:GetSyncStatus() or {}
        local msg = self:GetSyncStatusText()
        local progress = status.state == "IDLE" and 1 or status.progress or 0
        self:ShowSyncStatus(msg, progress)
    end
end
