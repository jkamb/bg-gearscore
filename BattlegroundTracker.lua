-- BG-GearScore Battleground Tracker
-- BG detection, player tracking, and team statistics

local addonName, addon = ...

-- Constants
local FACTION_HORDE = 0
local FACTION_ALLIANCE = 1
local WINNER_DRAW = 255
local MIN_PLAYERS_FOR_PREDICTION = 3  -- Minimum known players needed for win prediction

-- Helper: Get enemy faction
local function GetEnemyFaction(faction)
    return faction == FACTION_HORDE and FACTION_ALLIANCE or FACTION_HORDE
end

-- Tracking state
local currentBG = nil
local bgStartTime = nil
local bgInstanceID = nil  -- Unique instance ID from GetBattlefieldStatus (e.g., "5" for "WSG 5")
local bgWinner = nil  -- Captured when BG ends
local lastScoreboardUpdate = 0
local players = {
    [FACTION_HORDE] = {},
    [FACTION_ALLIANCE] = {},
}
local playerFaction = nil
local updateTimer = nil
local currentPrediction = nil  -- Current win prediction for this match
local predictionNeedsMoreMatches = false
local predictionMatchesNeeded = 0
local currentEnemyRating = nil  -- Combat rating estimate for enemy team
local currentFriendlyRating = nil  -- Combat rating estimate for friendly team

-- Initialize battleground tracker
function addon:InitializeBattlegroundTracker()
    -- Register BG-related events
    addon:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
        addon:OnZoneChanged()
    end)

    addon:RegisterEvent("UPDATE_BATTLEFIELD_STATUS", function()
        addon:OnBattlefieldStatusUpdate()
    end)

    addon:RegisterEvent("UPDATE_BATTLEFIELD_SCORE", function()
        addon:OnScoreboardUpdate()
    end)

    addon:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        addon:OnZoneChanged()
    end)

    -- Raid roster changes (players joining/leaving BG)
    addon:RegisterEvent("RAID_ROSTER_UPDATE", function()
        if addon:IsInBattleground() then
            -- Clear failed inspects on roster change so new players can be scanned
            addon:ClearFailedInspects()
            RequestBattlefieldScoreData()
        end
    end)

    -- Group roster changes (backup for TBC)
    addon:RegisterEvent("GROUP_ROSTER_UPDATE", function()
        if addon:IsInBattleground() then
            addon:ClearFailedInspects()
            RequestBattlefieldScoreData()
        end
    end)

    -- Check if already in BG on load
    C_Timer.After(1, function()
        addon:OnZoneChanged()
    end)

    addon:Debug("BattlegroundTracker initialized")
end

-- Handle zone change
function addon:OnZoneChanged()
    local wasInBG = currentBG ~= nil
    local isInBG = self:IsInBattleground()

    if isInBG and not wasInBG then
        -- Entered a battleground
        self:OnEnterBattleground()
    elseif wasInBG and not isInBG then
        -- Left a battleground
        self:OnLeaveBattleground()
    end
end

-- Handle battlefield status update
function addon:OnBattlefieldStatusUpdate()
    -- Check all BG slots for active BG
    for i = 1, GetMaxBattlefieldID() do
        local status, mapName, instanceID = GetBattlefieldStatus(i)
        if status == "active" then
            -- Capture the instance ID (unique per BG instance, e.g., 5 for "WSG 5")
            if instanceID and instanceID > 0 then
                bgInstanceID = instanceID
                addon:Debug("Captured BG instance ID:", instanceID)
            end
            if not currentBG then
                self:OnEnterBattleground()
            end
            return
        end
    end
end

-- Called when entering a battleground
function addon:OnEnterBattleground()
    currentBG = self:GetBattlegroundName()
    bgStartTime = GetTime()
    bgWinner = nil  -- Reset winner
    playerFaction = self:GetPlayerFaction()

    -- Try to get instance ID and map name from battlefield status
    bgInstanceID = nil
    for i = 1, GetMaxBattlefieldID() do
        local status, mapName, instanceID = GetBattlefieldStatus(i)
        if status == "active" then
            if instanceID and instanceID > 0 then
                bgInstanceID = instanceID
            end
            -- Use mapName from GetBattlefieldStatus as fallback if GetInstanceInfo failed
            if (not currentBG or currentBG == "Unknown Battleground") and mapName and mapName ~= "" then
                currentBG = mapName
            end
            break
        end
    end

    -- Final fallback if we still don't have a name
    currentBG = currentBG or "Unknown Battleground"

    -- Clear player lists
    players[0] = {}
    players[1] = {}

    -- Reset prediction and combat ratings
    currentPrediction = nil
    predictionNeedsMoreMatches = false
    predictionMatchesNeeded = 0
    currentEnemyRating = nil
    currentFriendlyRating = nil

    -- Clear session cache
    self:ClearSessionCache()

    addon:Debug("Entered BG:", currentBG, "Instance:", bgInstanceID or "unknown")
    addon:Print("Entered " .. currentBG .. " - Tracking friendly team GearScore")

    -- Auto-show scoreboard if enabled
    if self:GetSetting("autoShowInBG") and self.ShowScoreboard then
        C_Timer.After(2, function()
            if self:IsInBattleground() then
                self:ShowScoreboard()
            end
        end)
    end

    -- Start periodic updates
    self:StartScoreboardUpdates()

    -- Do a fast scan using TacoTip's cache
    C_Timer.After(1, function()
        if addon:IsInBattleground() then
            local scanned = addon:FastScanTacoTipCache()
            if scanned > 0 then
                addon:Debug("Fast scanned", scanned, "players from TacoTip cache")
            end
        end
    end)

    -- Trigger group sync if in group
    if addon.InitiateGroupSync then
        C_Timer.After(2, function()
            if addon:IsInBattleground() and addon:IsInGroup() then
                addon:InitiateGroupSync()
            end
        end)
    end

    -- Request initial scoreboard
    RequestBattlefieldScoreData()
end

-- Called when leaving a battleground
function addon:OnLeaveBattleground()
    if not currentBG then return end

    addon:Debug("Left BG:", currentBG)

    -- Stop updates
    self:StopScoreboardUpdates()

    -- Determine match result
    local result = self:DetermineMatchResult()

    -- Save match to history (only team stats, not personal stats)
    local matchData = {
        mapName = currentBG,
        instanceID = bgInstanceID,  -- Unique BG instance ID for sync deduplication
        result = result,
        duration = GetTime() - (bgStartTime or GetTime()),
        teams = self:GetTeamStats(),
        prediction = currentPrediction,  -- Store the prediction with the match
    }
    self:AddMatchToHistory(matchData)

    -- Hide scoreboard
    if self.HideScoreboard then
        self:HideScoreboard()
    end

    -- Clear state
    currentBG = nil
    bgStartTime = nil
    bgInstanceID = nil
    players[0] = {}
    players[1] = {}

    addon:Print("Match recorded: " .. (result == "win" and "Victory!" or result == "loss" and "Defeat" or "Draw"))
end

-- Start periodic scoreboard updates
function addon:StartScoreboardUpdates()
    if updateTimer then return end

    -- Request data immediately a few times to get full roster
    RequestBattlefieldScoreData()
    C_Timer.After(1, function() RequestBattlefieldScoreData() end)
    C_Timer.After(3, function() RequestBattlefieldScoreData() end)

    updateTimer = C_Timer.NewTicker(5, function()
        if addon:IsInBattleground() then
            RequestBattlefieldScoreData()
            -- Also do periodic fast scans to catch new TacoTip cache entries
            addon:FastScanTacoTipCache()
        else
            addon:StopScoreboardUpdates()
        end
    end)
end

-- Stop periodic updates
function addon:StopScoreboardUpdates()
    if updateTimer then
        updateTimer:Cancel()
        updateTimer = nil
    end
end

-- Handle scoreboard data update
function addon:OnScoreboardUpdate()
    if not self:IsInBattleground() then return end

    local numScores = GetNumBattlefieldScores()
    if numScores == 0 then return end

    -- Check for winner (capture it as soon as it's available)
    local winner = GetBattlefieldWinner()
    if winner ~= nil then
        bgWinner = winner
        addon:Debug("BG winner detected:", winner)
    end

    addon:Debug("Scoreboard update:", numScores, "players")

    -- Clear current lists
    players[0] = {}
    players[1] = {}

    -- Process all players
    for i = 1, numScores do
        -- TBC Anniversary API returns:
        -- name, killingBlows, honorKills, deaths, honorGained, faction, rank, race, class, classToken, damageDone, healingDone
        local name, killingBlows, honorKills, deaths, honorGained, faction, rank,
              race, class, classToken, damageDone, healingDone = GetBattlefieldScore(i)

        if name then
            -- Handle server names (Name-Server)
            local shortName = name:match("^([^-]+)") or name

            -- Use API faction directly (0 = Horde, 1 = Alliance)
            local detectedFaction = faction

            local playerData = {
                name = name,
                shortName = shortName,
                faction = detectedFaction,
                class = classToken or class,
                race = race,
                level = 0,  -- Will be filled from unit or cache
                killingBlows = killingBlows or 0,
                honorKills = honorKills or 0,
                deaths = deaths or 0,
                damage = damageDone or 0,
                healing = healingDone or 0,
                honorGained = honorGained or 0,
                gearScore = nil,  -- Will be filled if known
            }

            -- Try to get level from unit
            local unit = self:FindUnitByName(name) or self:FindUnitByName(shortName)
            if unit then
                playerData.level = UnitLevel(unit) or 0
            end

            -- Check if we have GearScore for this player
            local gs = self:GetPlayerGearScore(name)
            if gs then
                playerData.gearScore = gs
            elseif self:GetPlayerGearScore(shortName) then
                playerData.gearScore = self:GetPlayerGearScore(shortName)
            end

            -- Special handling for player's own GearScore
            local myName = UnitName("player")
            if (name == myName or shortName == myName) and not playerData.gearScore then
                local ttScore = TT_GS:GetScore("player")
                if ttScore and ttScore > 0 then
                    local _, class = UnitClass("player")
                    local data = {
                        gearScore = ttScore,
                        class = class,
                        itemCount = 16,
                    }
                    playerData.gearScore = ttScore
                    self:CachePlayer(name, data)
                    self:AddToSessionCache(name, data)
                end
            end

            -- Add to appropriate faction list
            if detectedFaction == FACTION_HORDE or detectedFaction == FACTION_ALLIANCE then
                table.insert(players[detectedFaction], playerData)
            end

            -- Queue friendly players for inspection (TacoTip cache works at any range)
            if detectedFaction == playerFaction and not playerData.gearScore then
                local unit = self:FindUnitByName(name) or self:FindUnitByName(shortName)
                if unit then
                    self:QueueInspect(name, unit, 3)
                end
            end
        end
    end

    -- Sort players by GearScore (known first, then by damage)
    for faction = 0, 1 do
        table.sort(players[faction], function(a, b)
            if a.gearScore and not b.gearScore then return true end
            if b.gearScore and not a.gearScore then return false end
            if a.gearScore and b.gearScore then
                return a.gearScore > b.gearScore
            end
            return a.damage > b.damage
        end)
    end

    lastScoreboardUpdate = GetTime()

    -- Calculate win prediction
    self:UpdateWinPrediction()

    -- Update UI
    if self.UpdateScoreboardUI then
        self:UpdateScoreboardUI()
    end
end

-- Update win prediction based on current team stats
function addon:UpdateWinPrediction()
    if not currentBG then return end

    local friendlyStats = self:GetFriendlyTeamStats()
    local enemyFaction = GetEnemyFaction(playerFaction)
    local allStats = self:GetTeamStats()
    local enemyStats = allStats[enemyFaction]

    -- Need at least some GS data to make a prediction
    if not friendlyStats or friendlyStats.knownCount < MIN_PLAYERS_FOR_PREDICTION then
        return
    end

    local friendlyGS = friendlyStats.avgGearScore
    local friendlyLvl = friendlyStats.avgLevel or 0
    local enemyLvl = (enemyStats and enemyStats.avgLevel) or 0

    -- Calculate and store combat ratings for both teams
    currentEnemyRating = self:CalculateEnemyCombatRating()
    currentFriendlyRating = self:CalculateFriendlyCombatRating()

    local prediction, needsMore, matchesNeeded = self:CalculateWinPrediction(
        currentBG, friendlyGS, friendlyLvl, enemyLvl, currentFriendlyRating, currentEnemyRating
    )

    currentPrediction = prediction
    predictionNeedsMoreMatches = needsMore
    predictionMatchesNeeded = matchesNeeded
end

-- Get current win prediction data
function addon:GetCurrentPrediction()
    return currentPrediction, predictionNeedsMoreMatches, predictionMatchesNeeded
end

-- Get players for a faction
function addon:GetPlayers(faction)
    if faction then
        return players[faction] or {}
    end
    return players
end

-- Get friendly team players
function addon:GetFriendlyPlayers()
    return players[playerFaction] or {}
end

-- Get enemy team players (only what's visible on scoreboard, no GS data)
function addon:GetEnemyPlayers()
    local enemyFaction = GetEnemyFaction(playerFaction)
    return players[enemyFaction] or {}
end

-- Calculate team statistics
function addon:GetTeamStats()
    local stats = {
        [0] = { avgGearScore = 0, medianGearScore = 0, avgLevel = 0, medianLevel = 0, knownCount = 0, totalCount = 0, totalDamage = 0, totalHealing = 0 },
        [1] = { avgGearScore = 0, medianGearScore = 0, avgLevel = 0, medianLevel = 0, knownCount = 0, totalCount = 0, totalDamage = 0, totalHealing = 0 },
    }

    self:ForEachFaction(function(faction)
        local gearScores = {}
        local levels = {}
        local teamPlayers = players[faction] or {}

        for _, player in ipairs(teamPlayers) do
            stats[faction].totalCount = stats[faction].totalCount + 1
            stats[faction].totalDamage = stats[faction].totalDamage + (player.damage or 0)
            stats[faction].totalHealing = stats[faction].totalHealing + (player.healing or 0)

            if player.gearScore and player.gearScore > 0 then
                table.insert(gearScores, player.gearScore)
                stats[faction].knownCount = stats[faction].knownCount + 1
            end

            if player.level and player.level > 0 then
                table.insert(levels, player.level)
            end
        end

        -- Calculate statistics using utility functions
        stats[faction].avgGearScore = self:CalculateAverage(gearScores)
        stats[faction].medianGearScore = self:CalculateMedian(gearScores)
        stats[faction].avgLevel = self:CalculateAverage(levels, 1)  -- One decimal place
        stats[faction].medianLevel = self:CalculateMedian(levels)
    end)

    return stats
end

-- Get friendly team stats only
function addon:GetFriendlyTeamStats()
    local stats = self:GetTeamStats()
    return stats[playerFaction]
end

-- Get current player's stats from scoreboard
function addon:GetPlayerStats()
    local myName = UnitName("player")

    for faction = 0, 1 do
        for _, player in ipairs(players[faction] or {}) do
            if player.name == myName or player.shortName == myName then
                return {
                    damage = player.damage,
                    healing = player.healing,
                    killingBlows = player.killingBlows,
                    deaths = player.deaths,
                    honorKills = player.honorKills,
                }
            end
        end
    end

    return {}
end

-- Determine match result
function addon:DetermineMatchResult()
    -- Use captured winner (captured during scoreboard updates while still in BG)
    local winner = bgWinner

    -- 255 = draw in battleground
    if winner == WINNER_DRAW then
        return "draw"
    elseif winner ~= nil then
        if winner == playerFaction then
            return "win"
        else
            return "loss"
        end
    end

    -- If no clear winner, check team scores/resources
    -- This is battleground-specific
    local teamStats = self:GetTeamStats()
    local myTeam = teamStats[playerFaction]
    local enemyTeam = teamStats[playerFaction == 0 and 1 or 0]

    if myTeam and enemyTeam then
        if myTeam.totalDamage > enemyTeam.totalDamage then
            return "unknown"  -- Can't determine from damage alone
        end
    end

    return "unknown"
end

-- Check if we're currently in a BG
function addon:IsTracking()
    return currentBG ~= nil
end

-- Get current BG name
function addon:GetCurrentBG()
    return currentBG
end

-- Get BG duration
function addon:GetBGDuration()
    if bgStartTime then
        return GetTime() - bgStartTime
    end
    return 0
end

-- Get player's faction (cached)
function addon:GetTrackedFaction()
    return playerFaction
end

-- Callback when a player is inspected (called from InspectQueue)
function addon:OnPlayerInspected(playerName, data)
    -- Update player data in our lists
    for faction = 0, 1 do
        for _, player in ipairs(players[faction] or {}) do
            if player.name == playerName or player.shortName == playerName then
                player.gearScore = data.gearScore
                break
            end
        end
    end

    -- Update UI
    if self.UpdateScoreboardUI then
        self:UpdateScoreboardUI()
    end
end

-- Constants for combat rating calculation
local COMBAT_RATING_MIN_MINUTES = 2  -- Minimum match time before calculating
local COMBAT_RATING_MIN_GS = 400     -- Minimum rating floor
local COMBAT_RATING_MAX_GS = 700     -- Maximum rating ceiling

-- Scaling factor to convert DPM+HPM to GS-equivalent rating
-- Tuned based on typical TBC BG performance:
-- Average player ~500 GS does roughly 1500 DPM + 500 HPM = 2000 combined
-- So we scale combined performance to match GS range
local COMBAT_RATING_SCALE = 0.25  -- 2000 combined / 0.25 = 500 GS equivalent

-- Calculate combat rating for a faction based on scoreboard performance
function addon:CalculateCombatRating(faction)
    if not bgStartTime then return nil end

    -- Check minimum match time (2 minutes)
    local matchMinutes = (GetTime() - bgStartTime) / 60
    if matchMinutes < COMBAT_RATING_MIN_MINUTES then
        return nil
    end

    -- Get team stats for the specified faction
    local allStats = self:GetTeamStats()
    local teamStats = allStats[faction]

    if not teamStats or teamStats.totalCount == 0 then
        return nil
    end

    -- Calculate damage per minute and healing per minute for the team
    local totalDamage = teamStats.totalDamage or 0
    local totalHealing = teamStats.totalHealing or 0
    local playerCount = teamStats.totalCount

    local dpm = totalDamage / matchMinutes
    local hpm = totalHealing / matchMinutes

    -- Average performance per player
    local avgPerformance = (dpm + hpm) / playerCount

    -- Scale to GS-equivalent rating
    local combatRating = avgPerformance * COMBAT_RATING_SCALE

    -- Clamp to reasonable GS range
    combatRating = math.max(COMBAT_RATING_MIN_GS, math.min(COMBAT_RATING_MAX_GS, combatRating))

    -- Round to nearest integer
    combatRating = math.floor(combatRating + 0.5)

    return combatRating, matchMinutes
end

-- Calculate enemy combat rating (convenience wrapper)
function addon:CalculateEnemyCombatRating()
    local enemyFaction = GetEnemyFaction(playerFaction)
    local rating, matchMinutes = self:CalculateCombatRating(enemyFaction)

    if rating then
        addon:Debug("Enemy combat rating:", string.format(
            "faction=%d, minutes=%.1f, rating=%d",
            enemyFaction, matchMinutes, rating
        ))
    end

    return rating
end

-- Calculate friendly combat rating (convenience wrapper)
function addon:CalculateFriendlyCombatRating()
    local rating, matchMinutes = self:CalculateCombatRating(playerFaction)

    if rating then
        addon:Debug("Friendly combat rating:", string.format(
            "faction=%d, minutes=%.1f, rating=%d",
            playerFaction, matchMinutes, rating
        ))
    end

    return rating
end

-- Get the current enemy combat rating (or nil if still calculating)
function addon:GetEnemyCombatRating()
    return currentEnemyRating
end

-- Get the current friendly combat rating (or nil if still calculating)
function addon:GetFriendlyCombatRating()
    return currentFriendlyRating
end

-- Check if we're still in the initial calculation period
function addon:IsCombatRatingCalculating()
    if not bgStartTime then return false end
    local matchMinutes = (GetTime() - bgStartTime) / 60
    return matchMinutes < COMBAT_RATING_MIN_MINUTES
end

-- Backwards compatibility alias
function addon:IsEnemyRatingCalculating()
    return self:IsCombatRatingCalculating()
end
