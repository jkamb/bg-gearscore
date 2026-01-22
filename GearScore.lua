-- BG-GearScore GearScore Calculation Engine
-- Requires TacoTip for GearScore calculation

local addonName, addon = ...

-- Inventory slot IDs
local INVSLOT_HEAD = 1
local INVSLOT_NECK = 2
local INVSLOT_SHOULDER = 3
local INVSLOT_CHEST = 5
local INVSLOT_WAIST = 6
local INVSLOT_LEGS = 7
local INVSLOT_FEET = 8
local INVSLOT_WRIST = 9
local INVSLOT_HANDS = 10
local INVSLOT_FINGER1 = 11
local INVSLOT_FINGER2 = 12
local INVSLOT_TRINKET1 = 13
local INVSLOT_TRINKET2 = 14
local INVSLOT_BACK = 15
local INVSLOT_MAINHAND = 16
local INVSLOT_OFFHAND = 17
local INVSLOT_RANGED = 18

-- All equipment slots to scan
local EQUIPMENT_SLOTS = {
    INVSLOT_HEAD,
    INVSLOT_NECK,
    INVSLOT_SHOULDER,
    INVSLOT_CHEST,
    INVSLOT_WAIST,
    INVSLOT_LEGS,
    INVSLOT_FEET,
    INVSLOT_WRIST,
    INVSLOT_HANDS,
    INVSLOT_FINGER1,
    INVSLOT_FINGER2,
    INVSLOT_TRINKET1,
    INVSLOT_TRINKET2,
    INVSLOT_BACK,
    INVSLOT_MAINHAND,
    INVSLOT_OFFHAND,
    INVSLOT_RANGED,
}

-- Check if TacoTip is available
function addon:HasTacoTip()
    return TT_GS and TT_GS.GetScore and TT_GS.GetItemScore
end

-- Calculate GearScore from cached item links using TacoTip
-- playerClass is required for class-specific modifiers (e.g., Hunter)
function addon:CalculateGearScoreFromItems(items, playerClass)
    if not items then return 0, 0 end

    local totalScore = 0
    local itemCount = 0
    local titanGrip = 1  -- Multiplier for 2H weapons when dual-wielding

    -- Check for Titan's Grip (dual 2H weapons)
    if items[INVSLOT_MAINHAND] and items[INVSLOT_OFFHAND] then
        local _, _, _, _, _, _, _, _, mainEquipLoc = GetItemInfo(items[INVSLOT_MAINHAND])
        local _, _, _, _, _, _, _, _, offEquipLoc = GetItemInfo(items[INVSLOT_OFFHAND])
        if mainEquipLoc == "INVTYPE_2HWEAPON" or offEquipLoc == "INVTYPE_2HWEAPON" then
            titanGrip = 0.5
        end
    end

    for slotId, itemLink in pairs(items) do
        -- TT_GS:GetItemScore returns: GearScore, ItemLevel, R, G, B, ItemEquipLoc
        local score = TT_GS:GetItemScore(itemLink) or 0

        -- Apply class-specific modifiers (matching TacoTip's GetScore behavior)
        if playerClass == "HUNTER" then
            if slotId == INVSLOT_MAINHAND or slotId == INVSLOT_OFFHAND then
                score = math.floor(score * 0.3164)
            elseif slotId == INVSLOT_RANGED then
                score = math.floor(score * 5.3224)
            end
        end

        -- Apply Titan's Grip penalty to main hand only (matching TacoTip)
        -- Offhand Titan's Grip is handled in TacoTip's separate offhand processing,
        -- but since we process all slots uniformly, we apply it here too
        if titanGrip ~= 1 and (slotId == INVSLOT_MAINHAND or slotId == INVSLOT_OFFHAND) then
            score = math.floor(score * titanGrip)
        end

        totalScore = totalScore + score
        itemCount = itemCount + 1

        addon:Debug("  Slot", slotId, "score:", score)
    end

    addon:Debug("Total GearScore:", totalScore, "from", itemCount, "items, class:", playerClass)

    return totalScore, itemCount
end

-- Get GearScore color based on score value (uses TacoTip's color function if available)
function addon:GetGearScoreColor(score)
    if not score or score <= 0 then
        return 0.5, 0.5, 0.5  -- Grey for unknown
    end

    -- Use TacoTip's color function if available
    if TT_GS and TT_GS.GetQuality then
        local r, g, b = TT_GS:GetQuality(score)
        if r then return r, g, b end
    end

    -- Fallback colors
    if score < 200 then
        return 0.6, 0.6, 0.6  -- Grey
    elseif score < 400 then
        return 0.0, 1.0, 0.0  -- Green
    elseif score < 600 then
        return 0.0, 0.5, 1.0  -- Blue
    elseif score < 800 then
        return 0.6, 0.2, 0.9  -- Purple
    elseif score < 1000 then
        return 1.0, 0.5, 0.0  -- Orange
    else
        return 1.0, 0.0, 0.0  -- Red
    end
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

-- Export equipment slots for other modules
addon.EQUIPMENT_SLOTS = EQUIPMENT_SLOTS
addon.INVSLOT_MAINHAND = INVSLOT_MAINHAND
addon.INVSLOT_OFFHAND = INVSLOT_OFFHAND
addon.INVSLOT_RANGED = INVSLOT_RANGED
