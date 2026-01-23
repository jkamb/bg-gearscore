-- BG-GearScore Inspect Queue
-- Fast scanning system using TacoTip/LibClassicInspector cache

local addonName, addon = ...

-- Get LibClassicInspector (used by TacoTip for inspections)
local LCI = LibStub("LibClassicInspector")

-- Session cache for current BG (faster than DB cache)
local sessionCache = {}

-- Track players we failed to scan (so we don't keep retrying)
local failedScans = {}

-- Initialize the inspect queue system
function addon:InitializeInspectQueue()
    addon:Debug("InspectQueue initialized (using TacoTip/LibClassicInspector)")
end

-- Clear session cache (called on BG exit)
function addon:ClearSessionCache()
    sessionCache = {}
    failedScans = {}
    addon:Debug("Session cache cleared")
end

-- Clear failed scans (called on roster change to allow new players)
function addon:ClearFailedInspects()
    failedScans = {}
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

-- Queue a player for inspection via TacoTip/LibClassicInspector
function addon:QueueInspect(playerName, unit, priority)
    if not playerName or not unit then return false end

    -- Check if already in session cache
    if sessionCache[playerName] then
        return false
    end

    -- Check if we already failed to scan this player
    if failedScans[playerName] then
        return false
    end

    -- Check if already in persistent cache (with valid data)
    local cached = self:GetCachedPlayer(playerName)
    if cached and cached.gearScore and cached.gearScore > 0 then
        -- Sanity check: reject suspiciously low cached scores
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
            -- Cached score is too low, likely bad data - clear it and re-scan
            addon:Debug("Clearing suspicious cached GS for:", playerName, "GS:", cached.gearScore)
            self:ClearCachedPlayer(playerName)
        end
    end

    -- Try TacoTip's cache first (instant, no range requirement)
    local ttScore = TT_GS:GetScore(unit)
    if ttScore and ttScore > 0 then
        -- TacoTip has cached data! Use it immediately
        local _, class = UnitClass(unit)
        local data = {
            gearScore = ttScore,
            class = class,
            itemCount = 16,  -- Estimated full set
        }
        addon:AddToSessionCache(playerName, data)
        addon:CachePlayer(playerName, data)

        if addon.OnPlayerInspected then
            addon:OnPlayerInspected(playerName, data)
        end

        addon:Debug("Instant scan via TacoTip cache:", playerName, "GS:", ttScore)
        return true
    end

    -- TacoTip doesn't have cached data yet - queue inspection via LibClassicInspector
    -- This will update TacoTip's cache, which we'll pick up on next fast scan
    local result = LCI:DoInspect(unit)
    if result and result > 0 then
        addon:Debug("Queued for inspection via LibClassicInspector:", playerName)
        return true
    else
        -- Can't inspect (out of range, not player, etc.)
        failedScans[playerName] = true
        addon:Debug("Failed to queue inspection:", playerName)
        return false
    end
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
    -- Clear session cache first
    sessionCache = {}

    -- Fast scan via TacoTip cache
    local scanned = self:FastScanTacoTipCache()

    -- Queue inspections for anyone not in TacoTip's cache yet
    local queued = 0
    if IsInRaid() then
        for i = 1, 40 do
            local unit = "raid" .. i
            if UnitExists(unit) and not UnitIsEnemy("player", unit) then
                local name = UnitName(unit)
                if name and not sessionCache[name] then
                    self:QueueInspect(name, unit, 5)
                    queued = queued + 1
                end
            end
        end
    else
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) then
                local name = UnitName(unit)
                if name and not sessionCache[name] then
                    self:QueueInspect(name, unit, 5)
                    queued = queued + 1
                end
            end
        end
    end

    addon:Print("Scanned", scanned, "from TacoTip cache, queued", queued, "for inspection via LibClassicInspector")
end
