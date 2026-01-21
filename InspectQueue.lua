-- BG-GearScore Inspect Queue
-- Throttled player inspection system with caching

local addonName, addon = ...

-- Inspection configuration
local INSPECT_THROTTLE = 1.5  -- Seconds between inspections (server limit)
local INSPECT_RANGE = 28      -- Yard range for inspection
local INSPECT_TIMEOUT = 5     -- Timeout for pending inspections

-- Queue state
local inspectQueue = {}       -- Players waiting to be inspected
local pendingInspect = nil    -- Currently pending inspection
local lastInspectTime = 0     -- Time of last inspection
local inspectTimer = nil      -- Timer handle

-- Session cache for current BG (faster than DB cache)
local sessionCache = {}

-- Track players we failed to inspect (so we don't keep retrying)
local failedInspects = {}

-- Initialize the inspect queue system
function addon:InitializeInspectQueue()
    -- Register for inspect events
    addon:RegisterEvent("INSPECT_READY", function(event)
        addon:OnInspectReady()
    end)

    addon:Debug("InspectQueue initialized")
end

-- Clear session cache (called on BG exit)
function addon:ClearSessionCache()
    sessionCache = {}
    failedInspects = {}
    inspectQueue = {}
    pendingInspect = nil
    addon:Debug("Session cache cleared")
end

-- Clear failed inspects (called on roster change to allow new players)
function addon:ClearFailedInspects()
    failedInspects = {}
end

-- Get player from session cache
function addon:GetSessionCache(playerName)
    return sessionCache[playerName]
end

-- Add player to session cache
function addon:AddToSessionCache(playerName, data)
    sessionCache[playerName] = {
        gearScore = data.gearScore,
        class = data.class,
        itemCount = data.itemCount,
        items = data.items,
        timestamp = GetTime(),
    }
end

-- Queue a player for inspection
function addon:QueueInspect(playerName, unit, priority)
    if not playerName or not unit then return false end

    -- Check if already in session cache
    if sessionCache[playerName] then
        return false
    end

    -- Check if we already failed to inspect this player
    if failedInspects[playerName] then
        return false
    end

    -- Check if already in persistent cache (with valid data)
    local cached = self:GetCachedPlayer(playerName)
    if cached and cached.gearScore and cached.gearScore > 0 then
        -- Add to session cache from persistent cache
        sessionCache[playerName] = {
            gearScore = cached.gearScore,
            class = cached.class,
            itemCount = cached.itemCount,
            timestamp = GetTime(),
            fromCache = true,
        }
        return false
    end

    -- Check if already queued
    for i, queued in ipairs(inspectQueue) do
        if queued.name == playerName then
            -- Update unit if provided (might be more current)
            queued.unit = unit
            return false
        end
    end

    -- Add to queue
    local entry = {
        name = playerName,
        unit = unit,
        priority = priority or 0,
        addedAt = GetTime(),
    }

    -- Insert based on priority (higher priority first)
    local inserted = false
    for i, queued in ipairs(inspectQueue) do
        if entry.priority > queued.priority then
            table.insert(inspectQueue, i, entry)
            inserted = true
            break
        end
    end
    if not inserted then
        table.insert(inspectQueue, entry)
    end

    -- Start processing if not already running
    self:ProcessInspectQueue()

    return true
end

-- Process the inspection queue
function addon:ProcessInspectQueue()
    -- Check if we're already waiting for an inspection
    if pendingInspect then
        -- Check for timeout
        if GetTime() - pendingInspect.startTime > INSPECT_TIMEOUT then
            addon:Debug("Inspection timed out for:", pendingInspect.name)
            pendingInspect = nil
        else
            return  -- Still waiting
        end
    end

    -- Check if queue is empty
    if #inspectQueue == 0 then
        return
    end

    -- Check throttle
    local timeSinceLastInspect = GetTime() - lastInspectTime
    if timeSinceLastInspect < INSPECT_THROTTLE then
        -- Schedule retry
        if not inspectTimer then
            inspectTimer = C_Timer.After(INSPECT_THROTTLE - timeSinceLastInspect + 0.1, function()
                inspectTimer = nil
                addon:ProcessInspectQueue()
            end)
        end
        return
    end

    -- Get next player from queue
    local entry = table.remove(inspectQueue, 1)
    if not entry then return end

    -- Try to find the unit by name (handles realm name mismatches)
    local unit = self:FindUnitByName(entry.name)
    if not unit then
        -- Player not in raid anymore, mark as failed so we don't retry
        failedInspects[entry.name] = true
        self:ProcessInspectQueue()
        return
    end

    -- Check if we can inspect this unit
    if not CanInspect(unit) then
        -- Can't inspect (maybe left BG), mark as failed
        failedInspects[entry.name] = true
        self:ProcessInspectQueue()
        return
    end

    -- Check if in range
    if not CheckInteractDistance(unit, 1) then
        -- Out of range, don't mark as failed - will retry on next scoreboard update
        self:ProcessInspectQueue()
        return
    end

    -- Start inspection
    pendingInspect = {
        name = entry.name,
        unit = unit,
        startTime = GetTime(),
    }

    lastInspectTime = GetTime()
    NotifyInspect(unit)

    -- Schedule timeout check
    C_Timer.After(INSPECT_TIMEOUT + 0.1, function()
        if pendingInspect and pendingInspect.name == entry.name then
            pendingInspect = nil
            addon:ProcessInspectQueue()
        end
    end)
end

-- Handle INSPECT_READY event
function addon:OnInspectReady()
    if not pendingInspect then
        -- Ignore stray INSPECT_READY events (common in BGs)
        return
    end

    local unit = pendingInspect.unit
    local playerName = pendingInspect.name

    -- Verify it's still the expected unit
    local shortName = playerName:match("^([^-]+)") or playerName
    local unitName = UnitName(unit)
    if not UnitExists(unit) or (unitName ~= playerName and unitName ~= shortName) then
        addon:Debug("Unit changed during inspection:", playerName)
        pendingInspect = nil
        self:ProcessInspectQueue()
        return
    end

    -- Read gear data
    local items = {}
    local hasAnyItem = false

    for _, slotId in ipairs(addon.EQUIPMENT_SLOTS) do
        local itemLink = GetInventoryItemLink(unit, slotId)
        if itemLink then
            items[slotId] = itemLink
            hasAnyItem = true
        end
    end

    if not hasAnyItem then
        addon:Debug("No items found for:", playerName)
        pendingInspect = nil
        self:ProcessInspectQueue()
        return
    end

    -- Calculate GearScore (try unit-based first for TacoTip, fallback to items)
    local gearScore, itemCount = self:CalculateGearScore(unit)
    if not gearScore or gearScore == 0 then
        -- Fallback to item-based calculation
        gearScore, itemCount = self:CalculateGearScoreFromItems(items)
    end
    local _, class = UnitClass(unit)

    -- Store in session cache
    local data = {
        gearScore = gearScore,
        class = class,
        itemCount = itemCount,
        items = items,
    }
    self:AddToSessionCache(playerName, data)

    -- Store in persistent cache
    self:CachePlayer(playerName, data)

    addon:Debug("Inspection complete:", playerName, "GS:", gearScore)

    -- Clear inspection state
    ClearInspectPlayer()
    pendingInspect = nil

    -- Fire callback for UI update
    if self.OnPlayerInspected then
        self:OnPlayerInspected(playerName, data)
    end

    -- Continue processing queue
    C_Timer.After(0.1, function()
        addon:ProcessInspectQueue()
    end)
end

-- Get full name with realm for comparison
local function GetUnitFullName(unit)
    local name, realm = UnitName(unit)
    if not name then return nil end
    if realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

-- Find a unit by player name (searches raid/party frames)
function addon:FindUnitByName(playerName)
    if not playerName then return nil end

    -- Extract short name for comparison
    local shortName = playerName:match("^([^-]+)") or playerName

    -- Check raid members
    for i = 1, 40 do
        local unit = "raid" .. i
        if UnitExists(unit) then
            local unitName = UnitName(unit)
            local fullName = GetUnitFullName(unit)
            if unitName == playerName or unitName == shortName or fullName == playerName then
                return unit
            end
        end
    end

    -- Check party members
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) then
            local unitName = UnitName(unit)
            local fullName = GetUnitFullName(unit)
            if unitName == playerName or unitName == shortName or fullName == playerName then
                return unit
            end
        end
    end

    -- Check player
    local myName = UnitName("player")
    local myFullName = GetUnitFullName("player")
    if myName == playerName or myName == shortName or myFullName == playerName then
        return "player"
    end

    -- Check target
    if UnitExists("target") then
        local targetName = UnitName("target")
        local targetFullName = GetUnitFullName("target")
        if targetName == playerName or targetName == shortName or targetFullName == playerName then
            return "target"
        end
    end

    return nil
end

-- Get current queue size
function addon:GetInspectQueueSize()
    return #inspectQueue
end

-- Check if player has known GearScore
function addon:HasGearScore(playerName)
    if sessionCache[playerName] then
        return true, sessionCache[playerName].gearScore
    end

    local cached = self:GetCachedPlayer(playerName)
    if cached and cached.gearScore then
        return true, cached.gearScore
    end

    return false, nil
end

-- Get player GearScore (from cache or session)
function addon:GetPlayerGearScore(playerName)
    if sessionCache[playerName] then
        return sessionCache[playerName].gearScore, sessionCache[playerName]
    end

    local cached = self:GetCachedPlayer(playerName)
    if cached then
        return cached.gearScore, cached
    end

    return nil, nil
end

-- Force scan of all nearby friendly players
function addon:ForceScan()
    -- Clear session cache to force re-inspection
    sessionCache = {}
    inspectQueue = {}

    -- Queue all raid/party members
    if IsInRaid() then
        for i = 1, 40 do
            local unit = "raid" .. i
            if UnitExists(unit) and not UnitIsEnemy("player", unit) then
                local name = UnitName(unit)
                if name then
                    self:QueueInspect(name, unit, 5)
                end
            end
        end
    else
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) then
                local name = UnitName(unit)
                if name then
                    self:QueueInspect(name, unit, 5)
                end
            end
        end
    end

    addon:Print("Queued", #inspectQueue, "players for inspection")
end
