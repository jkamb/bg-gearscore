local addonName, addon = ...

-- GroupSync: Lightweight cache sharing for players who enter BG together
-- Shares GearScore cache data via PARTY/RAID channels on BG entry

local PROTOCOL_VERSION = "V1"
local MSG_TYPE_GROUP = "GRP"
local MSG_REQUEST = "REQ"
local MSG_DATA = "DATA"

-- Timing constants
local REQUEST_WINDOW = 2.0      -- Seconds to collect responses after REQ
local MAX_PLAYERS_PER_MSG = 6   -- Limit players per DATA message (stay under 255 bytes)
local MAX_CACHE_AGE = 4 * 60 * 60  -- 4 hours in seconds

-- State management
local groupSyncState = "IDLE"  -- IDLE, REQUESTING, RECEIVING

function addon:InitializeGroupSync()
    addon:Debug("GroupSync initializing...")

    -- Set up message routing from GuildSync's handler
    addon.OnGroupMessage = function(message, channel, sender)
        self:OnGroupSyncMessage(message, channel, sender)
    end

    addon:Debug("GroupSync initialized")
end

-- Check if player is in a group (party or raid)
function addon:IsInGroup()
    return IsInRaid() or GetNumGroupMembers() > 0
end

-- Get appropriate communication channel (RAID for 6+ players, PARTY otherwise)
function addon:GetGroupChannel()
    return IsInRaid() and "RAID" or "PARTY"
end

-- Entry point: Called when entering a battleground
function addon:InitiateGroupSync()
    -- Verify conditions
    if not self.db.settings.groupSyncEnabled then
        addon:Debug("GroupSync disabled in settings")
        return
    end

    if not self:IsInBattleground() then
        addon:Debug("Not in battleground, skipping GroupSync")
        return
    end

    if not self:IsInGroup() then
        addon:Debug("Not in group, skipping GroupSync")
        return
    end

    if groupSyncState ~= "IDLE" then
        addon:Debug("GroupSync already in progress, state:", groupSyncState)
        return
    end

    addon:Debug("Initiating GroupSync...")
    self:SendGroupSyncRequest()
end

-- Send REQUEST message to group
function addon:SendGroupSyncRequest()
    local channel = self:GetGroupChannel()
    local message = string.format("%s|%s|%s", PROTOCOL_VERSION, MSG_TYPE_GROUP, MSG_REQUEST)

    addon:Debug("Sending GroupSync REQUEST to", channel)
    C_ChatInfo.SendAddonMessage("BGGS", message, channel)

    groupSyncState = "REQUESTING"

    -- Transition to RECEIVING state after REQUEST_WINDOW
    C_Timer.After(REQUEST_WINDOW, function()
        if groupSyncState == "REQUESTING" then
            groupSyncState = "RECEIVING"
            addon:Debug("GroupSync state: RECEIVING")

            -- Return to IDLE after collecting responses
            C_Timer.After(REQUEST_WINDOW, function()
                if groupSyncState == "RECEIVING" then
                    groupSyncState = "IDLE"
                    addon:Debug("GroupSync complete, state: IDLE")
                end
            end)
        end
    end)
end

-- Send DATA message with cached players
function addon:SendGroupSyncData()
    local channel = self:GetGroupChannel()
    local cachedPlayers = self:GetCacheToBroadcast()

    if #cachedPlayers == 0 then
        addon:Debug("No valid cached players to share")
        return
    end

    -- Build player data string
    local playerDataParts = {}
    for i, player in ipairs(cachedPlayers) do
        table.insert(playerDataParts, string.format("%s:%d:%d",
            player.name,
            player.gearScore,
            player.timestamp
        ))
    end
    local playerData = table.concat(playerDataParts, ";")

    -- Format: V1|GRP|DATA|count|playerData
    local message = string.format("%s|%s|%s|%d|%s",
        PROTOCOL_VERSION,
        MSG_TYPE_GROUP,
        MSG_DATA,
        #cachedPlayers,
        playerData
    )

    addon:Debug("Sending GroupSync DATA:", #cachedPlayers, "players to", channel)
    C_ChatInfo.SendAddonMessage("BGGS", message, channel)
end

-- Get list of cached players to broadcast (top 6 most recent, valid entries)
function addon:GetCacheToBroadcast()
    local candidates = {}
    local currentTime = time()

    -- Collect valid cached players from persistent cache
    if not self.db or not self.db.playerCache then
        return {}
    end

    for playerName, data in pairs(self.db.playerCache) do
        if data.gearScore and data.gearScore >= 100 then
            local age = currentTime - (data.timestamp or 0)
            if age < MAX_CACHE_AGE then
                table.insert(candidates, {
                    name = playerName,
                    gearScore = data.gearScore,
                    timestamp = data.timestamp,
                })
            end
        end
    end

    -- Sort by most recent first
    table.sort(candidates, function(a, b)
        return a.timestamp > b.timestamp
    end)

    -- Return top MAX_PLAYERS_PER_MSG
    local result = {}
    for i = 1, math.min(MAX_PLAYERS_PER_MSG, #candidates) do
        table.insert(result, candidates[i])
    end

    return result
end

-- Handle incoming group sync messages
function addon:OnGroupSyncMessage(message, channel, sender)
    -- Parse protocol version and message type
    local version, msgType, subType = string.match(message, "^([^|]+)|([^|]+)|([^|]+)")

    if version ~= PROTOCOL_VERSION then
        addon:Debug("Unknown protocol version:", version)
        return
    end

    if msgType ~= MSG_TYPE_GROUP then
        return  -- Not a group sync message
    end

    -- Get player name without realm
    local playerName = sender
    if string.find(sender, "-") then
        playerName = string.match(sender, "^([^-]+)")
    end

    if subType == MSG_REQUEST then
        self:OnGroupSyncRequest(playerName, channel)
    elseif subType == MSG_DATA then
        self:OnGroupSyncData(playerName, message)
    end
end

-- Handle REQUEST message - respond with DATA
function addon:OnGroupSyncRequest(sender, channel)
    addon:Debug("Received GroupSync REQUEST from", sender, "on", channel)

    -- Don't respond to our own request
    local myName = UnitName("player")
    if sender == myName then
        return
    end

    -- Wait a small random delay to avoid thundering herd
    local delay = math.random() * 0.5  -- 0-0.5 seconds
    C_Timer.After(delay, function()
        self:SendGroupSyncData()
    end)
end

-- Handle DATA message - populate cache
function addon:OnGroupSyncData(sender, message)
    -- Parse message: V1|GRP|DATA|count|playerData
    local count, playerData = string.match(message, "^[^|]+|[^|]+|[^|]+|(%d+)|(.+)$")

    if not count or not playerData then
        addon:Debug("Failed to parse GroupSync DATA from", sender)
        return
    end

    count = tonumber(count)
    addon:Debug("Received GroupSync DATA from", sender, ":", count, "players")

    -- Parse player entries: name-realm:gs:timestamp;name-realm:gs:timestamp;...
    local addedCount = 0
    for entry in string.gmatch(playerData, "[^;]+") do
        local name, gs, ts = string.match(entry, "^([^:]+):(%d+):(%d+)$")

        if name and gs and ts then
            local gearScore = tonumber(gs)
            local timestamp = tonumber(ts)

            -- Add to session cache via InspectQueue
            if self.AddToSessionCacheFromSync then
                local added = self:AddToSessionCacheFromSync(name, gearScore, timestamp, sender)
                if added then
                    addedCount = addedCount + 1
                end
            end
        end
    end

    if addedCount > 0 then
        addon:Debug("Added", addedCount, "players from", sender, "'s sync data")
    end
end

-- Debug command: Manually trigger group sync
function addon:TriggerGroupSyncDebug()
    if not self:IsInBattleground() then
        print("|cFFFF6B6BBG-GearScore:|r Not in a battleground")
        return
    end

    if not self:IsInGroup() then
        print("|cFFFF6B6BBG-GearScore:|r Not in a group")
        return
    end

    print("|cFFFF6B6BBG-GearScore:|r Manually triggering GroupSync...")
    groupSyncState = "IDLE"  -- Reset state
    self:InitiateGroupSync()
end
