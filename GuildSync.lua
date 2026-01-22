-- BG-GearScore Guild Sync
-- Syncs match history across guild members via hidden addon messages

local addonName, addon = ...

-- Addon message prefix (max 16 chars)
local ADDON_PREFIX = "BGGS"

-- Configuration
local MESSAGE_THROTTLE = 1.1        -- Seconds between messages
local SYNC_TIMEOUT = 30             -- Seconds to wait for sync completion
local RESPONSE_WINDOW = 5           -- Seconds to wait for peer responses
local AUTO_SYNC_DELAY = 10          -- Seconds after login before first sync
local AUTO_SYNC_INTERVAL = 1800     -- 30 minutes between auto-syncs (default)
local MAX_MATCHES_PER_SYNC = 20     -- Limit matches per sync to avoid spam
local MAX_MESSAGES_PER_SESSION = 100  -- Disconnect prevention

-- Sync states
local SYNC_STATES = {
    IDLE = "IDLE",
    ANNOUNCING = "ANNOUNCING",
    WAITING_RESPONSES = "WAITING_RESPONSES",
    REQUESTING = "REQUESTING",
    RECEIVING = "RECEIVING",
    SENDING = "SENDING",
}

-- Message types (V1 protocol)
local MSG_TYPES = {
    ANNOUNCE = "ANN",      -- Broadcast our match count/timestamp
    SUMMARY = "SUM",       -- Respond with our summary
    REQUEST = "REQ",       -- Request matches newer than timestamp
    CHUNK = "CHK",         -- Chunked match data
    COMPLETE = "CMP",      -- Sync complete notification
}

-- State variables
local syncState = SYNC_STATES.IDLE
local syncContext = {
    startTime = nil,
    peer = nil,
    expectedChunks = 0,
    receivedChunks = {},
    chunkSender = nil,
    totalMatches = 0,
    mergedMatches = 0,
    conflictsResolved = 0,
}

-- Message queue for throttling
local messageQueue = {}
local processingQueue = false
local messagesSentThisSession = 0

-- Timers
local syncTimeoutTimer = nil
local responseWindowTimer = nil
local autoSyncTimer = nil
local queueProcessTimer = nil

-- Peer tracking (for choosing best source)
local peerSummaries = {}

-- Callbacks for UI updates
local syncCallbacks = {}

-- Rate limiting per sender
local senderRateLimits = {}  -- [sender] = {count, resetTime}

-- Helper: Reset sync context
local function ResetSyncContext()
    syncContext = {
        startTime = nil,
        peer = nil,
        expectedChunks = 0,
        receivedChunks = {},
        chunkSender = nil,
        totalMatches = 0,
        mergedMatches = 0,
        conflictsResolved = 0,
    }
    peerSummaries = {}
end

-- Helper: Cancel all timers
local function CancelTimers()
    if syncTimeoutTimer then
        syncTimeoutTimer:Cancel()
        syncTimeoutTimer = nil
    end
    if responseWindowTimer then
        responseWindowTimer:Cancel()
        responseWindowTimer = nil
    end
    if queueProcessTimer then
        queueProcessTimer:Cancel()
        queueProcessTimer = nil
    end
end

-- Helper: Fire callbacks
local function FireCallback(eventType, data)
    for _, callback in ipairs(syncCallbacks) do
        local success, err = pcall(callback, eventType, data)
        if not success then
            addon:Debug("Sync callback error:", err)
        end
    end
end

-- Helper: Check rate limit for sender
local function CheckRateLimit(sender)
    local now = GetTime()
    local limit = senderRateLimits[sender]

    if not limit or now > limit.resetTime then
        senderRateLimits[sender] = {count = 1, resetTime = now + 60}
        return true
    end

    if limit.count >= 100 then  -- Max 100 messages per minute per sender
        addon:Debug("Rate limit exceeded for", sender)
        return false
    end

    limit.count = limit.count + 1
    return true
end

-- Helper: Format message with version prefix
local function FormatMessage(msgType, payload)
    return string.format("V%d:%s:%s", addon.SYNC_VERSION, msgType, payload or "")
end

-- Helper: Parse message
local function ParseMessage(message)
    local version, msgType, payload = string.match(message, "^V(%d+):(%w+):(.*)$")
    if not version then
        -- Try without payload
        version, msgType = string.match(message, "^V(%d+):(%w+)$")
        payload = ""
    end

    if not version or not msgType then
        return nil
    end

    return {
        version = tonumber(version),
        msgType = msgType,
        payload = payload or "",
    }
end

-- Initialize guild sync system
function addon:InitializeGuildSync()
    -- Check if player is in a guild
    if not IsInGuild() then
        addon:Debug("Not in guild - guild sync disabled")
        return
    end

    -- Register addon message prefix (TBC API)
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)
    elseif RegisterAddonMessagePrefix then
        RegisterAddonMessagePrefix(ADDON_PREFIX)
    end

    -- Register for addon messages
    addon:RegisterEvent("CHAT_MSG_ADDON", function(event, prefix, message, channel, sender)
        if prefix == ADDON_PREFIX then
            -- Route guild sync messages
            if channel == "GUILD" then
                self:OnGuildMessage(message, sender)
            -- Route group sync messages
            elseif (channel == "PARTY" or channel == "RAID") and addon.OnGroupMessage then
                addon.OnGroupMessage(message, channel, sender)
            end
        end
    end)

    -- Register for guild roster update (to handle joining guild mid-session)
    addon:RegisterEvent("GUILD_ROSTER_UPDATE", function()
        if IsInGuild() and not autoSyncTimer then
            self:StartAutoSync()
        end
    end)

    -- Start auto-sync system
    self:StartAutoSync()

    -- Schedule initial sync (delayed to allow guild roster to load)
    C_Timer.After(AUTO_SYNC_DELAY, function()
        if IsInGuild() then
            self:RequestGuildSync()
        end
    end)

    addon:Debug("GuildSync initialized")
end

-- Start periodic auto-sync
function addon:StartAutoSync()
    if autoSyncTimer then return end

    local interval = (self.db and self.db.settings and self.db.settings.guildSyncInterval) or AUTO_SYNC_INTERVAL

    local function AutoSyncTick()
        if IsInGuild() and syncState == SYNC_STATES.IDLE then
            self:RequestGuildSync()
        end
        autoSyncTimer = C_Timer.NewTimer(interval, AutoSyncTick)
    end

    autoSyncTimer = C_Timer.NewTimer(interval, AutoSyncTick)
end

-- Stop auto-sync
function addon:StopAutoSync()
    if autoSyncTimer then
        autoSyncTimer:Cancel()
        autoSyncTimer = nil
    end
end

-- Register a callback for sync events
function addon:RegisterSyncCallback(callback)
    if type(callback) == "function" then
        table.insert(syncCallbacks, callback)
    end
end

-- Abort current sync with reason
function addon:AbortSync(reason)
    addon:Debug("Sync aborted:", reason)

    CancelTimers()
    ResetSyncContext()
    syncState = SYNC_STATES.IDLE

    FireCallback("SYNC_ERROR", {reason = reason})
end

-- Request guild sync (manual or automatic trigger)
-- isManual: true if triggered by user command, false for auto-sync
function addon:RequestGuildSync(isManual)
    if not IsInGuild() then
        addon:Debug("Cannot sync - not in guild")
        return false
    end

    if syncState ~= SYNC_STATES.IDLE then
        addon:Debug("Sync already in progress, state:", syncState)
        return false
    end

    addon:Debug("Starting guild sync...", isManual and "(manual)" or "(auto)")

    -- Reset state
    ResetSyncContext()
    syncContext.startTime = GetTime()
    syncContext.isManual = isManual or false
    messagesSentThisSession = 0

    -- Get our summary
    local history = self:GetMatchHistory()
    local matchCount = #history
    local lastTimestamp = (history[1] and history[1].timestamp) or 0

    -- Send announce
    syncState = SYNC_STATES.ANNOUNCING
    local payload = string.format("%d,%d", matchCount, lastTimestamp)
    self:QueueMessage(FormatMessage(MSG_TYPES.ANNOUNCE, payload))

    -- Start response window timer
    syncState = SYNC_STATES.WAITING_RESPONSES
    responseWindowTimer = C_Timer.NewTimer(RESPONSE_WINDOW, function()
        self:OnResponseWindowClosed()
    end)

    -- Start overall timeout
    syncTimeoutTimer = C_Timer.NewTimer(SYNC_TIMEOUT, function()
        if syncState ~= SYNC_STATES.IDLE then
            self:AbortSync("Timeout")
        end
    end)

    FireCallback("SYNC_STARTED", {isManual = syncContext.isManual})

    -- Update last sync time
    if self.db and self.db.settings then
        self.db.settings.lastGuildSyncTime = time()
    end

    return true
end

-- Called when response window closes - pick best peer and request data
function addon:OnResponseWindowClosed()
    responseWindowTimer = nil

    if syncState ~= SYNC_STATES.WAITING_RESPONSES then
        return
    end

    -- Check if anyone responded
    local bestPeer = nil
    local bestCount = 0
    local bestTimestamp = 0

    for peer, summary in pairs(peerSummaries) do
        if summary.matchCount > bestCount or
           (summary.matchCount == bestCount and summary.lastTimestamp > bestTimestamp) then
            bestPeer = peer
            bestCount = summary.matchCount
            bestTimestamp = summary.lastTimestamp
        end
    end

    if not bestPeer then
        addon:Debug("No peers responded to sync request")
        CancelTimers()
        local isManual = syncContext.isManual
        ResetSyncContext()
        syncState = SYNC_STATES.IDLE
        FireCallback("SYNC_COMPLETE", {newMatches = 0, conflicts = 0, peer = nil, isManual = isManual})
        return
    end

    -- Determine what we need
    local history = self:GetMatchHistory()
    local ourLastTimestamp = (history[1] and history[1].timestamp) or 0

    -- Request matches newer than our newest
    syncState = SYNC_STATES.REQUESTING
    syncContext.peer = bestPeer

    local payload = tostring(ourLastTimestamp)
    self:QueueMessage(FormatMessage(MSG_TYPES.REQUEST, payload), bestPeer)

    addon:Debug("Requesting data from", bestPeer, "since", ourLastTimestamp)
    FireCallback("SYNC_PROGRESS", {status = "Requesting data from " .. bestPeer, progress = 0.2})
end

-- Handle incoming guild message
function addon:OnGuildMessage(message, sender)
    -- Ignore messages from self
    local playerName = UnitName("player")
    local shortSender = sender:match("^([^-]+)") or sender
    if shortSender == playerName then
        return
    end

    -- Rate limit check
    if not CheckRateLimit(sender) then
        return
    end

    -- Parse message
    local parsed = ParseMessage(message)
    if not parsed then
        addon:Debug("Failed to parse message from", sender, ":", message:sub(1, 50))
        return
    end

    -- Version check
    if parsed.version > addon.SYNC_VERSION then
        addon:Debug("Ignoring message from newer protocol version:", parsed.version)
        return
    end

    -- Route by message type
    if parsed.msgType == MSG_TYPES.ANNOUNCE then
        self:OnAnnounce(sender, parsed.payload)
    elseif parsed.msgType == MSG_TYPES.SUMMARY then
        self:OnSummary(sender, parsed.payload)
    elseif parsed.msgType == MSG_TYPES.REQUEST then
        self:OnRequest(sender, parsed.payload)
    elseif parsed.msgType == MSG_TYPES.CHUNK then
        self:OnChunk(sender, parsed.payload)
    elseif parsed.msgType == MSG_TYPES.COMPLETE then
        self:OnComplete(sender, parsed.payload)
    end
end

-- Handle ANNOUNCE message (someone else wants to sync)
function addon:OnAnnounce(sender, payload)
    addon:Debug("Received ANNOUNCE from", sender, ":", payload)

    -- Parse: matchCount,lastTimestamp
    local matchCount, lastTimestamp = payload:match("^(%d+),(%d+)$")
    matchCount = tonumber(matchCount) or 0
    lastTimestamp = tonumber(lastTimestamp) or 0

    -- Get our summary
    local history = self:GetMatchHistory()
    local ourCount = #history
    local ourTimestamp = (history[1] and history[1].timestamp) or 0

    -- If we have newer/more data, respond with summary
    if ourTimestamp > lastTimestamp or ourCount > matchCount then
        -- Random delay to avoid collision
        C_Timer.After(math.random() * 2, function()
            local respPayload = string.format("%d,%d", ourCount, ourTimestamp)
            self:QueueMessage(FormatMessage(MSG_TYPES.SUMMARY, respPayload))
        end)
    end
end

-- Handle SUMMARY message (peer response to our announce)
function addon:OnSummary(sender, payload)
    if syncState ~= SYNC_STATES.WAITING_RESPONSES then
        return
    end

    addon:Debug("Received SUMMARY from", sender, ":", payload)

    -- Parse: matchCount,lastTimestamp
    local matchCount, lastTimestamp = payload:match("^(%d+),(%d+)$")
    matchCount = tonumber(matchCount) or 0
    lastTimestamp = tonumber(lastTimestamp) or 0

    -- Store summary
    peerSummaries[sender] = {
        matchCount = matchCount,
        lastTimestamp = lastTimestamp,
    }
end

-- Handle REQUEST message (someone wants our data)
function addon:OnRequest(sender, payload)
    addon:Debug("Received REQUEST from", sender, ":", payload)

    -- Parse: afterTimestamp
    local afterTimestamp = tonumber(payload) or 0

    -- Get matches newer than requested timestamp (only those with valid instanceID)
    local history = self:GetMatchHistory()
    local matchesToSend = {}

    for _, match in ipairs(history) do
        if match.timestamp > afterTimestamp then
            -- Only sync matches with a valid instanceID (required for deduplication)
            if match.instanceID and match.instanceID > 0 then
                table.insert(matchesToSend, match)
            end
        end
        if #matchesToSend >= MAX_MATCHES_PER_SYNC then
            break
        end
    end

    if #matchesToSend == 0 then
        -- Nothing to send
        self:QueueMessage(FormatMessage(MSG_TYPES.COMPLETE, "0"), sender)
        return
    end

    addon:Debug("Sending", #matchesToSend, "matches to", sender)

    -- Serialize and chunk
    local serialized = self:SerializeMatches(matchesToSend)
    if not serialized then
        self:QueueMessage(FormatMessage(MSG_TYPES.COMPLETE, "0"), sender)
        return
    end

    local chunks = self:ChunkMessage(serialized)
    if not chunks then
        self:QueueMessage(FormatMessage(MSG_TYPES.COMPLETE, "0"), sender)
        return
    end

    -- Queue all chunks (we don't change our sync state since we're just responding)
    for _, chunk in ipairs(chunks) do
        local chunkPayload = string.format("%d/%d:%s", chunk.index, chunk.total, chunk.data)
        self:QueueMessage(FormatMessage(MSG_TYPES.CHUNK, chunkPayload), sender)
    end

    -- Send complete notification after chunks
    self:QueueMessage(FormatMessage(MSG_TYPES.COMPLETE, tostring(#matchesToSend)), sender)
end

-- Handle CHUNK message (receiving match data)
function addon:OnChunk(sender, payload)
    if syncState ~= SYNC_STATES.REQUESTING and syncState ~= SYNC_STATES.RECEIVING then
        return
    end

    -- Parse: index/total:data
    local chunkInfo, data = payload:match("^([^:]+):(.+)$")
    if not chunkInfo or not data then
        addon:Debug("Invalid CHUNK format from", sender)
        return
    end

    local index, total = chunkInfo:match("^(%d+)/(%d+)$")
    index = tonumber(index)
    total = tonumber(total)

    if not index or not total then
        addon:Debug("Invalid chunk info from", sender)
        return
    end

    -- Validate bounds
    if index < 1 or index > total or total > 1000 then
        addon:Debug("Invalid chunk bounds from", sender, "index:", index, "total:", total)
        return
    end

    addon:Debug("Received chunk", index, "/", total, "from", sender)

    -- Store chunk
    if syncState == SYNC_STATES.REQUESTING then
        -- First chunk - verify this is from the peer we requested from
        if syncContext.peer and syncContext.peer ~= sender then
            addon:Debug("Ignoring chunk from non-requested peer:", sender, "expected:", syncContext.peer)
            return
        end
        -- Switch to receiving state
        syncState = SYNC_STATES.RECEIVING
        syncContext.expectedChunks = total
        syncContext.chunkSender = sender
    end

    -- Verify sender matches (for subsequent chunks)
    if syncContext.chunkSender and syncContext.chunkSender ~= sender then
        addon:Debug("Chunk from unexpected sender:", sender)
        return
    end

    -- Verify total is consistent
    if syncContext.expectedChunks ~= total then
        addon:Debug("Chunk total mismatch from", sender, "expected:", syncContext.expectedChunks, "got:", total)
        return
    end

    syncContext.receivedChunks[index] = data

    -- Count received chunks properly (not using # which only counts contiguous)
    local receivedCount = 0
    for i = 1, syncContext.expectedChunks do
        if syncContext.receivedChunks[i] then
            receivedCount = receivedCount + 1
        end
    end

    -- Update progress
    local progress = 0.2 + (0.6 * (receivedCount / syncContext.expectedChunks))
    FireCallback("SYNC_PROGRESS", {
        status = string.format("Receiving data %d/%d", receivedCount, total),
        progress = progress,
    })
end

-- Handle COMPLETE message
function addon:OnComplete(sender, payload)
    addon:Debug("Received COMPLETE from", sender, ":", payload)

    local matchCount = tonumber(payload) or 0

    -- If we were receiving, process the data
    if syncState == SYNC_STATES.RECEIVING and syncContext.chunkSender == sender then
        self:ProcessReceivedData()
    elseif syncState == SYNC_STATES.REQUESTING then
        -- Peer had nothing to send
        CancelTimers()
        local isManual = syncContext.isManual
        ResetSyncContext()
        syncState = SYNC_STATES.IDLE
        FireCallback("SYNC_COMPLETE", {newMatches = 0, conflicts = 0, peer = sender, isManual = isManual})
    end
end

-- Process received chunk data
function addon:ProcessReceivedData()
    addon:Debug("Processing received data...")

    FireCallback("SYNC_PROGRESS", {status = "Processing data...", progress = 0.9})

    -- Reassemble chunks
    local data = self:ReassembleChunks(syncContext.receivedChunks, syncContext.expectedChunks)
    if not data then
        self:AbortSync("Failed to reassemble chunks")
        return
    end

    -- Deserialize
    local matches = self:DeserializeMatches(data)
    if not matches or #matches == 0 then
        self:AbortSync("Failed to deserialize match data")
        return
    end

    addon:Debug("Deserialized", #matches, "matches")

    -- Merge matches
    local merged = 0
    local conflicts = 0

    for _, match in ipairs(matches) do
        -- Validate
        local valid, err = self:ValidateMatch(match, syncContext.chunkSender)
        if not valid then
            addon:Debug("Skipping invalid match:", err)
        else
            local wasConflict = self:MergeMatch(match)
            merged = merged + 1
            if wasConflict then
                conflicts = conflicts + 1
            end
        end
    end

    addon:Debug("Merged", merged, "matches,", conflicts, "conflicts resolved")

    -- Complete
    CancelTimers()
    local peer = syncContext.peer
    local isManual = syncContext.isManual
    ResetSyncContext()
    syncState = SYNC_STATES.IDLE

    FireCallback("SYNC_COMPLETE", {newMatches = merged, conflicts = conflicts, peer = peer, isManual = isManual})

    -- Only print message for manual sync or if new matches were found
    if isManual or merged > 0 then
        addon:Print("Guild sync complete: " .. merged .. " new matches")
    end
end

-- Queue message for throttled sending
function addon:QueueMessage(message, target)
    -- Disconnect prevention
    if messagesSentThisSession >= MAX_MESSAGES_PER_SESSION then
        addon:Debug("Message limit reached, aborting")
        self:AbortSync("Message limit exceeded")
        return
    end

    table.insert(messageQueue, {message = message, target = target})

    if not processingQueue then
        self:ProcessMessageQueue()
    end
end

-- Process message queue (throttled)
function addon:ProcessMessageQueue()
    if #messageQueue == 0 then
        processingQueue = false
        return
    end

    processingQueue = true

    local entry = table.remove(messageQueue, 1)
    messagesSentThisSession = messagesSentThisSession + 1

    -- Send message
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        if entry.target then
            C_ChatInfo.SendAddonMessage(ADDON_PREFIX, entry.message, "WHISPER", entry.target)
        else
            C_ChatInfo.SendAddonMessage(ADDON_PREFIX, entry.message, "GUILD")
        end
    else
        if entry.target then
            SendAddonMessage(ADDON_PREFIX, entry.message, "WHISPER", entry.target)
        else
            SendAddonMessage(ADDON_PREFIX, entry.message, "GUILD")
        end
    end

    addon:Debug("Sent:", entry.message:sub(1, 60), entry.target and ("to " .. entry.target) or "")

    -- Schedule next message
    if #messageQueue > 0 then
        queueProcessTimer = C_Timer.After(MESSAGE_THROTTLE, function()
            self:ProcessMessageQueue()
        end)
    else
        processingQueue = false
    end
end

-- Get current sync status
function addon:GetSyncStatus()
    return {
        state = syncState,
        lastSyncTime = (self.db and self.db.settings and self.db.settings.lastGuildSyncTime) or 0,
        isInGuild = IsInGuild(),
        peer = syncContext.peer,
        progress = syncState == SYNC_STATES.RECEIVING and
            (syncContext.expectedChunks > 0 and (#syncContext.receivedChunks / syncContext.expectedChunks) or 0) or
            (syncState == SYNC_STATES.IDLE and 1 or 0),
    }
end

-- Check if sync is enabled
function addon:IsGuildSyncEnabled()
    if self.db and self.db.settings then
        return self.db.settings.guildSyncEnabled ~= false
    end
    return true
end

-- Enable/disable guild sync
function addon:SetGuildSyncEnabled(enabled)
    if self.db and self.db.settings then
        self.db.settings.guildSyncEnabled = enabled
        if enabled then
            self:StartAutoSync()
        else
            self:StopAutoSync()
        end
    end
end
