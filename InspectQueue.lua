-- BG-GearScore Inspect Queue
-- Throttled player inspection system with caching

local addonName, addon = ...

-- Inspection configuration
local INSPECT_THROTTLE = 0.5  -- Seconds between inspections (faster since we use TacoTip's cache)
local INSPECT_TIMEOUT = 3     -- Timeout for pending inspections (reduced since we're faster)

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

-- Add player to session cache from group sync (no inspection)
function addon:AddToSessionCacheFromSync(playerName, gearScore, timestamp, source)
    -- Only accept if not already in session cache
    if sessionCache[playerName] then
        return false
    end

    -- Validate GearScore (minimum sanity check)
    if gearScore < addon.MIN_VALID_GEARSCORE then
        addon:Debug("Rejecting invalid GS from sync:", playerName, gearScore)
        return false
    end

    -- Validate timestamp (within 4 hours)
    local MAX_CACHE_AGE = 4 * 60 * 60  -- 4 hours in seconds
    if (time() - timestamp) > MAX_CACHE_AGE then
        addon:Debug("Rejecting stale data from sync:", playerName, "age:", time() - timestamp)
        return false
    end

    -- Add to session cache
    sessionCache[playerName] = {
        gearScore = gearScore,
        timestamp = GetTime(),
        fromGroupSync = true,
        syncSource = source,
    }

    addon:Debug("Added from group sync:", playerName, "GS:", gearScore, "from:", source)
    return true
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
        -- Sanity check: reject suspiciously low cached scores
        -- A player with items should have at least ~150 GS (even in greens)
        if cached.gearScore >= addon.MIN_VALID_GEARSCORE then
            -- Add to session cache from persistent cache
            sessionCache[playerName] = {
                gearScore = cached.gearScore,
                class = cached.class,
                itemCount = cached.itemCount,
                timestamp = GetTime(),
                fromCache = true,
            }
            return false
        else
            -- Cached score is too low, likely bad data - clear it and re-inspect
            addon:Debug("Clearing suspicious cached GS for:", playerName, "GS:", cached.gearScore)
            self:ClearCachedPlayer(playerName)
        end
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

-- Re-queue a player at the back of the queue (for retries)
-- This allows other players to be processed while item data loads
function addon:RequeueInspect(playerName, unit, retryCount)
    local entry = {
        name = playerName,
        unit = unit,
        priority = -1,  -- Low priority so it goes to the back
        retryCount = retryCount,
        addedAt = GetTime(),
    }
    table.insert(inspectQueue, entry)
    addon:Debug("Re-queued", playerName, "at position", #inspectQueue)
end

-- Process the inspection queue
function addon:ProcessInspectQueue()
    -- Check if we're already waiting for an inspection
    if pendingInspect then
        if HasInspectTimedOut(pendingInspect) then
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
    if not CanInspectNow() then
        ScheduleInspectRetry(self)
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

    -- Try TacoTip's cached score first (instant, no range requirement)
    local ttScore = TT_GS:GetScore(unit)
    if ttScore and ttScore > 0 then
        -- TacoTip has cached data! Use it immediately
        local _, class = UnitClass(unit)
        local data = {
            gearScore = ttScore,
            class = class,
            itemCount = 16,  -- Estimated full set
        }
        addon:AddToSessionCache(entry.name, data)
        addon:CachePlayer(entry.name, data)

        if addon.OnPlayerInspected then
            addon:OnPlayerInspected(entry.name, data)
        end

        addon:Debug("Fast scan via TacoTip cache:", entry.name, "GS:", ttScore)

        -- Continue to next player immediately
        C_Timer.After(0.05, function()
            addon:ProcessInspectQueue()
        end)
        return
    end

    -- TacoTip doesn't have cached data, do full inspection
    -- Check if we can inspect this unit (range + inspectable)
    if not CanInspect(unit) then
        -- Can't inspect (maybe left BG), mark as failed
        failedInspects[entry.name] = true
        self:ProcessInspectQueue()
        return
    end

    -- Check if in range (only needed for NotifyInspect)
    if not CheckInteractDistance(unit, 1) then
        -- Out of range, re-queue at back so we try again when they're in range
        self:RequeueInspect(entry.name, unit, entry.retryCount or 0)
        self:ProcessInspectQueue()
        return
    end

    pendingInspect = {
        name = entry.name,
        unit = unit,
        startTime = GetTime(),
        retryCount = entry.retryCount or 0,
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

-- Helper: Verify unit is still valid for inspection
local function VerifyInspectUnit(unit, playerName)
    local shortName = playerName:match("^([^-]+)") or playerName
    local unitName = UnitName(unit)
    return UnitExists(unit) and (unitName == playerName or unitName == shortName)
end

-- Helper: Read all equipment items from unit
local function ReadEquipmentItems(unit)
    local items = {}
    local hasAnyItem = false
    local hasIncompleteItem = false

    for _, slotId in ipairs(addon.EQUIPMENT_SLOTS) do
        local itemLink = GetInventoryItemLink(unit, slotId)
        local hasItem = GetInventoryItemID(unit, slotId)

        if itemLink then
            items[slotId] = itemLink
            hasAnyItem = true
            -- Check if item info is loaded
            local _, _, _, itemLevel = GetItemInfo(itemLink)
            if not itemLevel then
                hasIncompleteItem = true
            end
        elseif hasItem then
            -- Slot has an item but link isn't available yet
            hasIncompleteItem = true
        end
    end

    return items, hasAnyItem, hasIncompleteItem
end

-- Helper: Count items with links
local function CountItems(items)
    local count = 0
    for _ in pairs(items) do
        count = count + 1
    end
    return count
end

-- Helper: Validate GearScore is reasonable for item count
local function IsGearScoreReasonable(gearScore, itemCount)
    local MIN_EXPECTED_GS_PER_ITEM = 15  -- Very conservative
    local expectedMinScore = itemCount * MIN_EXPECTED_GS_PER_ITEM
    return gearScore == 0 or gearScore >= expectedMinScore
end

-- Helper: Check if pending inspection has timed out
local function HasInspectTimedOut(pending)
    return pending and (GetTime() - pending.startTime > INSPECT_TIMEOUT)
end

-- Helper: Check if enough time has passed since last inspect (throttle check)
local function CanInspectNow()
    return (GetTime() - lastInspectTime) >= INSPECT_THROTTLE
end

-- Helper: Schedule inspection retry after throttle period
local function ScheduleInspectRetry(addon)
    if inspectTimer then return end  -- Already scheduled

    local delay = INSPECT_THROTTLE - (GetTime() - lastInspectTime) + 0.1
    inspectTimer = C_Timer.After(delay, function()
        inspectTimer = nil
        addon:ProcessInspectQueue()
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
    local retryCount = pendingInspect.retryCount or 0

    -- Verify unit is still valid
    if not VerifyInspectUnit(unit, playerName) then
        addon:Debug("Unit changed during inspection:", playerName)
        pendingInspect = nil
        self:ProcessInspectQueue()
        return
    end

    -- Read equipment items
    addon:Debug("Reading gear for:", playerName)
    local items, hasAnyItem, hasIncompleteItem = ReadEquipmentItems(unit)
    addon:Debug("Found", hasAnyItem and "items" or "no items", "incomplete:", hasIncompleteItem)

    -- If no items found or item info not loaded yet, re-queue to back of line
    -- This gives time for item cache to populate while we process other players
    local MAX_RETRIES = 5
    if (not hasAnyItem or hasIncompleteItem) and retryCount < MAX_RETRIES then
        addon:Debug("Incomplete item data for:", playerName, "re-queuing (attempt", retryCount + 1, "of", MAX_RETRIES, ")")
        ClearInspectPlayer()
        pendingInspect = nil
        -- Re-queue at back with incremented retry count
        self:RequeueInspect(playerName, unit, retryCount + 1)
        self:ProcessInspectQueue()
        return
    end

    if not hasAnyItem then
        addon:Debug("No items found for:", playerName, "after", MAX_RETRIES, "attempts")
        pendingInspect = nil
        self:ProcessInspectQueue()
        return
    end

    -- Get class for class-specific modifiers (e.g., Hunter weapon scaling)
    local _, class = UnitClass(unit)

    -- Calculate GearScore from the collected item links
    -- We use item-based calculation because we have reliable item data from the inspection
    -- TT_GS:GetScore(unit) can be unreliable during inspections as it may not see all gear
    local gearScore, itemCount = self:CalculateGearScoreFromItems(items, class)

    -- Validate GearScore is reasonable for item count
    local itemsWithLinks = CountItems(items)

    if not IsGearScoreReasonable(gearScore, itemsWithLinks) and retryCount < MAX_RETRIES then
        addon:Debug("GearScore suspiciously low for:", playerName,
            "GS:", gearScore, "items:", itemsWithLinks,
            "- re-queuing (attempt", retryCount + 1, "of", MAX_RETRIES, ")")
        ClearInspectPlayer()
        pendingInspect = nil
        self:RequeueInspect(playerName, unit, retryCount + 1)
        self:ProcessInspectQueue()
        return
    end

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

    addon:Debug("Inspection complete:", playerName, "GS:", gearScore, "items:", itemsWithLinks)

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

-- Fast scan using TacoTip's cache (no inspection needed)
function addon:FastScanTacoTipCache()
    local scanned = 0

    -- Scan all raid/party members
    if IsInRaid() then
        for i = 1, 40 do
            local unit = "raid" .. i
            if UnitExists(unit) and not UnitIsEnemy("player", unit) then
                local name = UnitName(unit)
                if name and not sessionCache[name] then
                    local ttScore = TT_GS:GetScore(unit)
                    if ttScore and ttScore > 0 then
                        local _, class = UnitClass(unit)
                        local data = {
                            gearScore = ttScore,
                            class = class,
                            itemCount = 16,
                        }
                        self:AddToSessionCache(name, data)
                        self:CachePlayer(name, data)

                        if self.OnPlayerInspected then
                            self:OnPlayerInspected(name, data)
                        end

                        scanned = scanned + 1
                    end
                end
            end
        end
    else
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) then
                local name = UnitName(unit)
                if name and not sessionCache[name] then
                    local ttScore = TT_GS:GetScore(unit)
                    if ttScore and ttScore > 0 then
                        local _, class = UnitClass(unit)
                        local data = {
                            gearScore = ttScore,
                            class = class,
                            itemCount = 16,
                        }
                        self:AddToSessionCache(name, data)
                        self:CachePlayer(name, data)

                        if self.OnPlayerInspected then
                            self:OnPlayerInspected(name, data)
                        end

                        scanned = scanned + 1
                    end
                end
            end
        end
    end

    return scanned
end

-- Force scan of all nearby friendly players
function addon:ForceScan()
    -- First try fast scan via TacoTip cache
    local fastScanned = self:FastScanTacoTipCache()

    -- Clear session cache to force re-inspection for any remaining
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

    addon:Print("Fast scanned", fastScanned, "from cache, queued", #inspectQueue, "for inspection")
end
