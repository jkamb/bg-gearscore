-- BG-GearScore GearScore Helpers
-- Wrapper functions for TacoTip GearScore API

local addonName, addon = ...

-- Check if TacoTip is available
function addon:HasTacoTip()
    return TT_GS and TT_GS.GetScore and TT_GS.GetQuality
end

-- Get GearScore color based on score value (uses TacoTip's color function)
function addon:GetGearScoreColor(score)
    if not score or score <= 0 then
        return 0.5, 0.5, 0.5  -- Grey for unknown
    end

    -- Use TacoTip's color function (TacoTip is a required dependency)
    local r, g, b = TT_GS:GetQuality(score)
    return r, g, b
end

-- Get GearScore color as hex string
function addon:GetGearScoreColorHex(score)
    local r, g, b = self:GetGearScoreColor(score)
    return string.format("%02x%02x%02x", r*255, g*255, b*255)
end

-- Get GearScore rating text
function addon:GetGearScoreRating(score)
    if not score or score <= 0 then
        return "Unknown"
    elseif score < 200 then
        return "Starter"
    elseif score < 400 then
        return "Normal"
    elseif score < 600 then
        return "Heroic"
    elseif score < 800 then
        return "Kara/T4"
    elseif score < 1000 then
        return "T5"
    else
        return "T6/Sunwell"
    end
end
