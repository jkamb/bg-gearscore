-- BG-GearScore Sync Serializer
-- Handles serialization, chunking, and match fingerprinting for guild sync

local addonName, addon = ...

-- Version constants
addon.SYNC_VERSION = 1  -- Protocol version

-- Chunk configuration
local CHUNK_SIZE = 240  -- Safe message size (255 limit - overhead)

-- Field delimiter (pipe can't appear in map names)
local DELIM = "|"
local TEAM_DELIM = ","

--[[ Serialization Format V1
    timestamp|mapName|instanceID|result|duration|prediction|team0|team1

    Team format:
    avgGS,medGS,avgLvl,medLvl,knownCount,totalCount,dmg,heal

    instanceID is the BG instance number from GetBattlefieldStatus (e.g., 5 for "WSG 5")
    This allows matching the same BG instance across different players for sync deduplication.
    If instanceID is 0 or nil, fallback to timestamp-based matching.

    Example:
    1737484920|Warsong Gulch|5|win|845|72|1850,1900,70,70,8,10,125000,50000|1750,1800,69,69,7,10,100000,40000
]]

-- Serialize a single match to a string
function addon:SerializeMatch(match)
    if not match or not match.timestamp or not match.mapName then
        return nil
    end

    -- Serialize team data
    local function SerializeTeam(team)
        if not team then
            return "0,0,0,0,0,0,0,0"
        end
        return string.format("%d%s%d%s%s%s%s%s%d%s%d%s%d%s%d",
            team.avgGearScore or 0, TEAM_DELIM,
            team.medianGearScore or 0, TEAM_DELIM,
            team.avgLevel or 0, TEAM_DELIM,
            team.medianLevel or 0, TEAM_DELIM,
            team.knownCount or 0, TEAM_DELIM,
            team.totalCount or 0, TEAM_DELIM,
            team.totalDamage or 0, TEAM_DELIM,
            team.totalHealing or 0
        )
    end

    local team0 = (match.teams and match.teams[0]) and SerializeTeam(match.teams[0]) or "0,0,0,0,0,0,0,0"
    local team1 = (match.teams and match.teams[1]) and SerializeTeam(match.teams[1]) or "0,0,0,0,0,0,0,0"

    return string.format("%d%s%s%s%d%s%s%s%d%s%d%s%s%s%s",
        match.timestamp,
        DELIM,
        match.mapName or "Unknown",
        DELIM,
        match.instanceID or 0,  -- BG instance ID for deduplication
        DELIM,
        match.result or "unknown",
        DELIM,
        match.duration or 0,
        DELIM,
        match.prediction or 0,
        DELIM,
        team0,
        DELIM,
        team1
    )
end

-- Deserialize a string back to a match table
function addon:DeserializeMatch(str)
    if not str or str == "" then
        return nil
    end

    -- Split by main delimiter
    local parts = {}
    for part in string.gmatch(str, "[^|]+") do
        table.insert(parts, part)
    end

    -- Format V1 has 8 parts: timestamp, mapName, instanceID, result, duration, prediction, team0, team1
    if #parts < 8 then
        addon:Debug("Deserialization failed: not enough parts, got", #parts)
        return nil
    end

    -- Parse team data
    local function ParseTeam(teamStr)
        if not teamStr or teamStr == "" then
            return nil
        end

        local values = {}
        for val in string.gmatch(teamStr, "[^,]+") do
            table.insert(values, tonumber(val) or 0)
        end

        if #values < 8 then
            return nil
        end

        return {
            avgGearScore = values[1],
            medianGearScore = values[2],
            avgLevel = values[3],
            medianLevel = values[4],
            knownCount = values[5],
            totalCount = values[6],
            totalDamage = values[7],
            totalHealing = values[8],
        }
    end

    local team0 = ParseTeam(parts[7])
    local team1 = ParseTeam(parts[8])

    if not team0 or not team1 then
        addon:Debug("Deserialization failed: invalid team data")
        return nil
    end

    local instanceID = tonumber(parts[3])
    -- Treat 0 as nil (no instance ID available)
    if instanceID == 0 then
        instanceID = nil
    end

    return {
        timestamp = tonumber(parts[1]),
        mapName = parts[2],
        instanceID = instanceID,  -- BG instance ID for deduplication
        result = parts[4],
        duration = tonumber(parts[5]),
        prediction = tonumber(parts[6]),
        teams = {
            [0] = team0,
            [1] = team1,
        },
    }
end

-- Serialize multiple matches (for bulk transfer)
-- Format: count;match1;match2;match3...
function addon:SerializeMatches(matches)
    if not matches or #matches == 0 then
        return nil
    end

    local serialized = {}
    for _, match in ipairs(matches) do
        local s = self:SerializeMatch(match)
        if s then
            table.insert(serialized, s)
        end
    end

    if #serialized == 0 then
        return nil
    end

    return #serialized .. ";" .. table.concat(serialized, ";")
end

-- Deserialize multiple matches
function addon:DeserializeMatches(str)
    if not str or str == "" then
        return nil
    end

    -- Parse count
    local countStr, rest = string.match(str, "^(%d+);(.+)$")
    if not countStr or not rest then
        addon:Debug("DeserializeMatches failed: invalid format")
        return nil
    end

    local expectedCount = tonumber(countStr)

    -- Split matches
    local matches = {}
    for matchStr in string.gmatch(rest, "[^;]+") do
        local match = self:DeserializeMatch(matchStr)
        if match then
            table.insert(matches, match)
        end
    end

    if #matches ~= expectedCount then
        addon:Debug("DeserializeMatches warning: expected", expectedCount, "got", #matches)
        -- Still return what we got
    end

    return matches
end

-- Generate a unique fingerprint for a match (for deduplication)
-- Requires instanceID - matches without it cannot be synced reliably.
-- Fingerprint format: mapHash_instanceID_roundedTimestamp
function addon:GetMatchFingerprint(match)
    if not match or not match.mapName then
        return nil
    end

    -- Require valid instance ID for sync
    if not match.instanceID or match.instanceID <= 0 then
        return nil
    end

    -- Simple hash of map name (just use first 3 chars + length)
    local mapHash = string.sub(match.mapName, 1, 3) .. tostring(#match.mapName)

    -- Include approximate timestamp (rounded to 10 min) to handle instance ID reuse
    -- BG instance IDs can be reused after the BG ends
    local roundedTime = math.floor((match.timestamp or 0) / 600) * 600  -- 10 min buckets

    return string.format("%s_%d_%d",
        mapHash,
        match.instanceID,
        roundedTime
    )
end

-- Get fingerprints for multiple matches (for summary comparison)
function addon:GetMatchFingerprints(matches)
    if not matches then return {} end

    local fingerprints = {}
    for _, match in ipairs(matches) do
        local fp = self:GetMatchFingerprint(match)
        if fp then
            table.insert(fingerprints, fp)
        end
    end
    return fingerprints
end

-- Chunk a message into multiple parts if needed
-- Returns array of {index, total, data} tables
function addon:ChunkMessage(data)
    if not data then return nil end

    local dataLen = string.len(data)

    if dataLen <= CHUNK_SIZE then
        -- Fits in one message
        return {{index = 1, total = 1, data = data}}
    end

    -- Need to chunk
    local chunks = {}
    local remaining = data
    local chunkNum = 1

    while string.len(remaining) > 0 do
        local chunk = string.sub(remaining, 1, CHUNK_SIZE)
        table.insert(chunks, {
            index = chunkNum,
            total = 0,  -- Will be set after
            data = chunk,
        })
        remaining = string.sub(remaining, CHUNK_SIZE + 1)
        chunkNum = chunkNum + 1
    end

    -- Set total count
    local totalChunks = #chunks
    for _, chunk in ipairs(chunks) do
        chunk.total = totalChunks
    end

    return chunks
end

-- Reassemble chunks back into original data
-- chunks: table keyed by index
-- expected: total number of chunks expected
function addon:ReassembleChunks(chunks, expected)
    if not chunks or expected <= 0 then
        return nil
    end

    -- Check we have all chunks
    for i = 1, expected do
        if not chunks[i] then
            addon:Debug("ReassembleChunks: missing chunk", i)
            return nil
        end
    end

    -- Concatenate in order
    local parts = {}
    for i = 1, expected do
        table.insert(parts, chunks[i])
    end

    return table.concat(parts)
end

-- Validate a deserialized match has reasonable values
function addon:ValidateMatch(match, sender)
    if not match then
        return false, "nil match"
    end

    -- Check required fields
    if not match.timestamp or match.timestamp <= 0 then
        return false, "invalid timestamp"
    end

    -- Timestamp shouldn't be in the future (allow 1 hour clock drift)
    if match.timestamp > time() + 3600 then
        return false, "timestamp in future"
    end

    -- Timestamp shouldn't be too old (before TBC)
    if match.timestamp < 1136073600 then  -- Jan 1, 2006
        return false, "timestamp too old"
    end

    if not match.mapName or match.mapName == "" then
        return false, "missing mapName"
    end

    if not match.teams or not match.teams[0] or not match.teams[1] then
        return false, "missing team data"
    end

    -- Validate team stats are reasonable
    for faction = 0, 1 do
        local team = match.teams[faction]

        -- GearScore should be 0-10000 (TBC max is around 4000)
        if team.avgGearScore and (team.avgGearScore < 0 or team.avgGearScore > 10000) then
            return false, "unreasonable avgGearScore"
        end

        -- Known count shouldn't exceed total
        if (team.knownCount or 0) > (team.totalCount or 0) then
            return false, "knownCount > totalCount"
        end

        -- Total count should be reasonable (1-80 for a BG)
        if team.totalCount and (team.totalCount < 0 or team.totalCount > 80) then
            return false, "unreasonable totalCount"
        end

        -- Level should be 1-70 for TBC
        if team.avgLevel and (team.avgLevel < 1 or team.avgLevel > 75) then
            return false, "unreasonable avgLevel"
        end
    end

    return true
end

-- Calculate total knownCount for a match (used for conflict resolution)
function addon:GetMatchKnownCount(match)
    if not match or not match.teams then
        return 0
    end

    local total = 0
    for faction = 0, 1 do
        local team = match.teams[faction]
        if team then
            total = total + (team.knownCount or 0)
        end
    end
    return total
end
