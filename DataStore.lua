-- BG-GearScore DataStore
-- SavedVariables management and match history persistence

local addonName, addon = ...

-- Default database structure
local DEFAULT_DB = {
    settings = {
        showMinimapButton = true,
        minimapButtonAngle = 225,
        autoShowInBG = true,
        maxHistoryEntries = 100,
        cacheExpireHours = 4,  -- Cache expires after 4 hours
        debugMode = false,
    },
    history = {},
    playerCache = {},
}

-- Initialize the data store
function addon:InitializeDataStore()
    -- Create or load saved variables
    if not BGGearScoreDB then
        BGGearScoreDB = {}
    end

    -- Merge defaults with saved data
    self.db = self:MergeDefaults(BGGearScoreDB, DEFAULT_DB)

    -- Migrate old cacheExpireDays to cacheExpireHours
    if self.db.settings.cacheExpireDays then
        self.db.settings.cacheExpireHours = self.db.settings.cacheExpireDays * 24
        self.db.settings.cacheExpireDays = nil
    end

    -- Clean up old cache entries
    self:CleanupCache()

    addon:Debug("DataStore initialized")
end

-- Deep merge defaults with saved data
function addon:MergeDefaults(saved, defaults)
    if type(saved) ~= "table" then
        return self:DeepCopy(defaults)
    end

    local result = {}

    -- Copy all defaults
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            result[k] = self:MergeDefaults(saved[k], v)
        else
            result[k] = saved[k] ~= nil and saved[k] or v
        end
    end

    -- Preserve any extra keys from saved data (like history entries)
    for k, v in pairs(saved) do
        if result[k] == nil then
            result[k] = v
        end
    end

    -- Update the global reference
    BGGearScoreDB = result

    return result
end

-- Deep copy a table
function addon:DeepCopy(orig)
    local copy
    if type(orig) == "table" then
        copy = {}
        for k, v in pairs(orig) do
            copy[k] = self:DeepCopy(v)
        end
    else
        copy = orig
    end
    return copy
end

-- Save database (called automatically, but can be forced)
function addon:SaveDB()
    BGGearScoreDB = self.db
end

-- Player Cache Functions

-- Get cached player data
function addon:GetCachedPlayer(playerName)
    if not self.db or not self.db.playerCache then return nil end

    local cached = self.db.playerCache[playerName]
    if cached then
        -- Check if cache is still valid (within expiration period)
        local expireTime = self.db.settings.cacheExpireHours * 60 * 60
        if (time() - (cached.timestamp or 0)) < expireTime then
            return cached
        else
            -- Cache expired, remove it
            self.db.playerCache[playerName] = nil
        end
    end
    return nil
end

-- Cache player data
function addon:CachePlayer(playerName, data)
    if not self.db or not playerName then return end

    self.db.playerCache[playerName] = {
        gearScore = data.gearScore,
        class = data.class,
        itemCount = data.itemCount,
        timestamp = time(),
    }

    addon:Debug("Cached player:", playerName, "GS:", data.gearScore)
end

-- Clear player from cache
function addon:ClearCachedPlayer(playerName)
    if self.db and self.db.playerCache then
        self.db.playerCache[playerName] = nil
    end
end

-- Clean up expired cache entries
function addon:CleanupCache()
    if not self.db or not self.db.playerCache then return end

    local expireTime = self.db.settings.cacheExpireHours * 60 * 60
    local currentTime = time()
    local removed = 0

    for playerName, data in pairs(self.db.playerCache) do
        if (currentTime - (data.timestamp or 0)) >= expireTime then
            self.db.playerCache[playerName] = nil
            removed = removed + 1
        end
    end

    if removed > 0 then
        addon:Debug("Cleaned up", removed, "expired cache entries")
    end
end

-- Match History Functions

-- Add a match to history
function addon:AddMatchToHistory(matchData)
    if not self.db or not self.db.history then return end

    -- Create match record (only team stats, not personal stats)
    local record = {
        timestamp = time(),
        mapName = matchData.mapName or "Unknown",
        result = matchData.result or "unknown",
        duration = matchData.duration or 0,
        teams = matchData.teams or {},
        prediction = matchData.prediction,  -- Win prediction at end of match
    }

    -- Insert at beginning (most recent first)
    table.insert(self.db.history, 1, record)

    -- Trim history to max entries
    while #self.db.history > self.db.settings.maxHistoryEntries do
        table.remove(self.db.history)
    end

    addon:Debug("Added match to history:", record.mapName, record.result)
end

-- Get match history
function addon:GetMatchHistory()
    if not self.db or not self.db.history then return {} end
    return self.db.history
end

-- Get match count
function addon:GetMatchCount()
    if not self.db or not self.db.history then return 0 end
    return #self.db.history
end

-- Get match by index
function addon:GetMatch(index)
    if not self.db or not self.db.history then return nil end
    return self.db.history[index]
end

-- Clear all history
function addon:ClearHistory()
    if self.db then
        self.db.history = {}
        addon:Print("Match history cleared.")
    end
end

-- Get win/loss statistics
function addon:GetStats()
    local stats = {
        total = 0,
        wins = 0,
        losses = 0,
        draws = 0,
        winRate = 0,
        maps = {},
    }

    if not self.db or not self.db.history then return stats end

    for _, match in ipairs(self.db.history) do
        stats.total = stats.total + 1

        if match.result == "win" then
            stats.wins = stats.wins + 1
        elseif match.result == "loss" then
            stats.losses = stats.losses + 1
        else
            stats.draws = stats.draws + 1
        end

        -- Track by map
        local mapName = match.mapName or "Unknown"
        if not stats.maps[mapName] then
            stats.maps[mapName] = {wins = 0, losses = 0, total = 0}
        end
        stats.maps[mapName].total = stats.maps[mapName].total + 1
        if match.result == "win" then
            stats.maps[mapName].wins = stats.maps[mapName].wins + 1
        elseif match.result == "loss" then
            stats.maps[mapName].losses = stats.maps[mapName].losses + 1
        end
    end

    if stats.total > 0 then
        stats.winRate = math.floor((stats.wins / stats.total) * 100)
    end

    return stats
end

-- Settings Functions

-- Get a setting value
function addon:GetSetting(key)
    if self.db and self.db.settings then
        return self.db.settings[key]
    end
    return DEFAULT_DB.settings[key]
end

-- Set a setting value
function addon:SetSetting(key, value)
    if self.db and self.db.settings then
        self.db.settings[key] = value
        addon:Debug("Setting changed:", key, "=", tostring(value))
    end
end

-- Reset settings to defaults
function addon:ResetSettings()
    if self.db then
        self.db.settings = self:DeepCopy(DEFAULT_DB.settings)
        addon:Print("Settings reset to defaults.")
    end
end

-- Format timestamp for display
function addon:FormatTimestamp(timestamp)
    if not timestamp then return "Unknown" end
    return date("%Y-%m-%d %H:%M", timestamp)
end

-- Format duration for display
function addon:FormatDuration(seconds)
    if not seconds or seconds <= 0 then return "0:00" end
    local mins = math.floor(seconds / 60)
    local secs = seconds % 60
    return string.format("%d:%02d", mins, secs)
end

-- Win Prediction Functions

-- Helper to get friendly team avg gear score from match data
-- Note: This is also defined in HistoryFrame.lua for UI purposes
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

-- Get map-specific statistics from history
function addon:GetMapStats(mapName)
    local stats = {
        matchCount = 0,
        winCount = 0,
        winRate = 0.5,  -- Default 50%
        avgWinningGS = 0,
        totalWinningGS = 0,
        winningGSCount = 0,
    }

    if not self.db or not self.db.history or not mapName then return stats end

    for _, match in ipairs(self.db.history) do
        if match.mapName == mapName then
            stats.matchCount = stats.matchCount + 1

            if match.result == "win" then
                stats.winCount = stats.winCount + 1

                -- Get friendly team GS from this winning match
                local teamGS = self:GetFriendlyTeamGsFromMatch(match)
                if teamGS and teamGS > 0 then
                    stats.totalWinningGS = stats.totalWinningGS + teamGS
                    stats.winningGSCount = stats.winningGSCount + 1
                end
            end
        end
    end

    -- Calculate win rate
    if stats.matchCount > 0 then
        stats.winRate = stats.winCount / stats.matchCount
    end

    -- Calculate average winning GS
    if stats.winningGSCount > 0 then
        stats.avgWinningGS = stats.totalWinningGS / stats.winningGSCount
    end

    return stats
end

-- Calculate win prediction for current match
-- Returns: prediction (0-100), needsMoreMatches (boolean), matchesNeeded (number)
-- friendlyRating/enemyRating are optional - combat ratings based on team performance (after 2 min)
function addon:CalculateWinPrediction(mapName, friendlyGS, friendlyLvl, enemyLvl, friendlyRating, enemyRating)
    local MIN_MATCHES = 10

    local mapStats = self:GetMapStats(mapName)

    -- Check if we have enough history
    if mapStats.matchCount < MIN_MATCHES then
        return nil, true, MIN_MATCHES - mapStats.matchCount
    end

    -- Base win rate from historical data
    local baseWinRate = mapStats.winRate * 100  -- Convert to percentage

    -- GS bonus: +5% per 100 GS above historical average
    local gsBonus = 0
    if mapStats.avgWinningGS > 0 and friendlyGS and friendlyGS > 0 then
        gsBonus = ((friendlyGS - mapStats.avgWinningGS) / 100) * 5
    end

    -- Level bonus: +3% per level advantage
    local lvlBonus = 0
    if friendlyLvl and enemyLvl and friendlyLvl > 0 and enemyLvl > 0 then
        local levelDiff = friendlyLvl - enemyLvl
        lvlBonus = levelDiff * 3
    end

    -- Combat performance comparison bonus (only when both ratings are available)
    -- Uses actual combat performance instead of just gear score for more accurate prediction
    -- +5% per 100 rating advantage (stronger weight since this is real performance data)
    local combatBonus = 0
    if friendlyRating and enemyRating then
        local ratingDiff = friendlyRating - enemyRating
        combatBonus = (ratingDiff / 100) * 5
    end

    -- Calculate final prediction, clamped to 5-95%
    local prediction = baseWinRate + gsBonus + lvlBonus + combatBonus
    prediction = math.max(5, math.min(95, prediction))

    addon:Debug("Win prediction:", string.format(
        "base=%.1f%%, gsBonus=%.1f%%, lvlBonus=%.1f%%, combatBonus=%.1f%%, final=%.1f%%",
        baseWinRate, gsBonus, lvlBonus, combatBonus, prediction
    ))

    return math.floor(prediction + 0.5), false, 0
end

-- Get prediction accuracy statistics
-- A prediction is considered "correct" if:
-- - Prediction was >50% and result was win, OR
-- - Prediction was <=50% and result was loss
function addon:GetPredictionAccuracy()
    local stats = {
        totalPredictions = 0,
        correctPredictions = 0,
        accuracy = 0,
    }

    if not self.db or not self.db.history then return stats end

    for _, match in ipairs(self.db.history) do
        -- Only count matches with a prediction and a definitive result
        if match.prediction and (match.result == "win" or match.result == "loss") then
            stats.totalPredictions = stats.totalPredictions + 1

            local predictedWin = match.prediction > 50
            local actualWin = match.result == "win"

            if predictedWin == actualWin then
                stats.correctPredictions = stats.correctPredictions + 1
            end
        end
    end

    if stats.totalPredictions > 0 then
        stats.accuracy = math.floor((stats.correctPredictions / stats.totalPredictions) * 100)
    end

    return stats
end
