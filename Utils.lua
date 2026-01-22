-- BG-GearScore Utility Functions
-- Common reusable utilities shared across modules

local addonName, addon = ...

-- Constants
addon.MIN_VALID_GEARSCORE = 100  -- Minimum GearScore to consider valid

-- Mathematical utilities

-- Calculate median of a numeric array
function addon:CalculateMedian(values)
    if not values or #values == 0 then return 0 end

    local sorted = {}
    for _, v in ipairs(values) do
        table.insert(sorted, v)
    end
    table.sort(sorted)

    local mid = math.floor(#sorted / 2)
    if #sorted % 2 == 0 then
        return math.floor((sorted[mid] + sorted[mid + 1]) / 2)
    else
        return sorted[mid + 1]
    end
end

-- Calculate average of a numeric array
function addon:CalculateAverage(values, decimals)
    if not values or #values == 0 then return 0 end

    local sum = 0
    for _, v in ipairs(values) do
        sum = sum + v
    end

    local avg = sum / #values

    if decimals then
        local multiplier = 10 ^ decimals
        return math.floor(avg * multiplier) / multiplier
    else
        return math.floor(avg)
    end
end

-- Iteration helpers

-- Execute callback for each faction (0 and 1)
function addon:ForEachFaction(callback)
    for faction = 0, 1 do
        callback(faction)
    end
end

-- Timer management helpers

-- Create a cancellable timer with automatic cleanup
function addon:CreateTimer(delay, callback)
    local timer = C_Timer.After(delay, callback)
    return timer
end

-- Cancel a timer if it exists
function addon:CancelTimer(timer)
    if timer then
        timer:Cancel()
    end
    return nil
end

-- Rate limiting utility

-- Create a new rate limiter
-- @param maxRequests Maximum number of requests allowed
-- @param window Time window in seconds
function addon:CreateRateLimiter(maxRequests, window)
    return {
        limits = {},
        maxRequests = maxRequests,
        window = window,

        -- Check if key is within rate limit
        check = function(self, key)
            local now = GetTime()
            local limit = self.limits[key]

            if not limit or now > limit.resetTime then
                self.limits[key] = {count = 1, resetTime = now + self.window}
                return true
            end

            if limit.count >= self.maxRequests then
                return false
            end

            limit.count = limit.count + 1
            return true
        end,

        -- Reset rate limit for a specific key
        reset = function(self, key)
            self.limits[key] = nil
        end,

        -- Clear all rate limits
        clear = function(self)
            self.limits = {}
        end,
    }
end

-- Message queue utility

-- Create a throttled message queue
-- @param throttle Delay between messages in seconds
-- @param sendFn Function called to send each message: sendFn(message, target)
function addon:CreateMessageQueue(throttle, sendFn)
    local queue = {
        items = {},
        throttle = throttle,
        processing = false,
        timer = nil,
        sendFn = sendFn,

        -- Add message to queue
        enqueue = function(self, message, target)
            table.insert(self.items, {message = message, target = target})
            if not self.processing then
                self:process()
            end
        end,

        -- Process next message in queue
        process = function(self)
            if #self.items == 0 then
                self.processing = false
                if self.timer then
                    self.timer:Cancel()
                    self.timer = nil
                end
                return
            end

            self.processing = true
            local entry = table.remove(self.items, 1)

            -- Send message
            self.sendFn(entry.message, entry.target)

            -- Schedule next message
            if #self.items > 0 then
                self.timer = C_Timer.After(self.throttle, function()
                    self:process()
                end)
            else
                self.processing = false
            end
        end,

        -- Get queue size
        size = function(self)
            return #self.items
        end,

        -- Clear queue
        clear = function(self)
            self.items = {}
            self.processing = false
            if self.timer then
                self.timer:Cancel()
                self.timer = nil
            end
        end,
    }

    return queue
end

-- String utilities

-- Truncate string to maximum length
function addon:TruncateString(str, maxLen)
    if not str then return "" end
    if #str <= maxLen then return str end
    return str:sub(1, maxLen)
end

-- Cache validation utilities

-- Check if cached data is valid
function addon:IsCacheValid(cached, maxAge)
    if not cached then return false end

    -- Check expiration
    if maxAge and cached.timestamp then
        local age = time() - cached.timestamp
        if age > maxAge then
            return false
        end
    end

    -- Check minimum GearScore
    if cached.gearScore and cached.gearScore < self.MIN_VALID_GEARSCORE then
        return false
    end

    return true
end

-- Filter cache entries by criteria
function addon:FilterCache(cache, filterFn, maxAge)
    if not cache then return {} end

    local filtered = {}
    for key, data in pairs(cache) do
        if self:IsCacheValid(data, maxAge) and (not filterFn or filterFn(key, data)) then
            filtered[key] = data
        end
    end

    return filtered
end
