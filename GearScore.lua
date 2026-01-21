-- BG-GearScore GearScore Calculation Engine
-- Uses TacoTip if available, otherwise falls back to built-in formula

local addonName, addon = ...

-- Flag to track if TacoTip is available
local hasTacoTip = false

-- Check for TacoTip on load
local function CheckForTacoTip()
    if TT_GS and TT_GS.GetScore then
        hasTacoTip = true
        addon:Debug("TacoTip detected, using TT_GS:GetScore()")
        return true
    end
    return false
end

-- Delayed check (TacoTip might load after us)
C_Timer.After(1, CheckForTacoTip)

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

-- Slot modifiers based on item equip location (from TacoTip)
-- Maps INVTYPE_* to slot modifier
local GS_ItemTypes = {
    ["INVTYPE_HEAD"] = 1.0000,
    ["INVTYPE_NECK"] = 0.5625,
    ["INVTYPE_SHOULDER"] = 0.7500,
    ["INVTYPE_CHEST"] = 1.0000,
    ["INVTYPE_ROBE"] = 1.0000,
    ["INVTYPE_WAIST"] = 0.7500,
    ["INVTYPE_LEGS"] = 1.0000,
    ["INVTYPE_FEET"] = 0.7500,
    ["INVTYPE_WRIST"] = 0.5625,
    ["INVTYPE_HAND"] = 0.7500,
    ["INVTYPE_FINGER"] = 0.5625,
    ["INVTYPE_TRINKET"] = 0.3164,
    ["INVTYPE_CLOAK"] = 0.5625,
    ["INVTYPE_WEAPON"] = 1.0000,
    ["INVTYPE_WEAPONMAINHAND"] = 1.0000,
    ["INVTYPE_WEAPONOFFHAND"] = 1.0000,
    ["INVTYPE_HOLDABLE"] = 1.0000,
    ["INVTYPE_SHIELD"] = 1.0000,
    ["INVTYPE_2HWEAPON"] = 2.0000,
    ["INVTYPE_RANGED"] = 0.3164,
    ["INVTYPE_RANGEDRIGHT"] = 0.3164,
    ["INVTYPE_THROWN"] = 0.3164,
    ["INVTYPE_RELIC"] = 0.3164,
}

-- Quality formula constants (from TacoTip)
-- For ItemLevel > 120 (high level items)
local GS_Formula_A = {
    [4] = { A = 91.45, B = 0.65 },   -- Epic
    [3] = { A = 81.375, B = 0.8125 }, -- Rare
    [2] = { A = 73.0, B = 1.0 },     -- Uncommon
}

-- For ItemLevel <= 120 (lower level items like TBC)
local GS_Formula_B = {
    [4] = { A = 26.0, B = 1.2 },    -- Epic
    [3] = { A = 0.75, B = 1.8 },    -- Rare
    [2] = { A = 8.0, B = 2.0 },     -- Uncommon
    [1] = { A = 0.0, B = 2.25 },    -- Common
    [0] = { A = 0.0, B = 2.5 },     -- Poor
}

-- Calculate GearScore for a single item
-- Formula: floor(((ItemLevel - A) / B) * SlotMOD * 1.8618)
local function CalculateItemScore(itemLink, slotId)
    if not itemLink then return 0 end

    local _, _, quality, itemLevel, _, _, _, _, itemEquipLoc = GetItemInfo(itemLink)
    if not itemLevel or not quality then return 0 end

    -- Skip items with no equip location or quality too low/high
    if quality < 0 or quality > 4 then
        -- Treat quality 5+ (legendary, artifact, heirloom) as epic
        quality = 4
    end

    -- Get slot modifier from equip location
    local slotMod = GS_ItemTypes[itemEquipLoc]
    if not slotMod then
        -- Fallback based on slot ID
        if slotId == INVSLOT_HEAD or slotId == INVSLOT_CHEST or slotId == INVSLOT_LEGS then
            slotMod = 1.0
        elseif slotId == INVSLOT_SHOULDER or slotId == INVSLOT_WAIST or slotId == INVSLOT_HANDS or slotId == INVSLOT_FEET then
            slotMod = 0.75
        elseif slotId == INVSLOT_NECK or slotId == INVSLOT_WRIST or slotId == INVSLOT_FINGER1 or slotId == INVSLOT_FINGER2 or slotId == INVSLOT_BACK then
            slotMod = 0.5625
        elseif slotId == INVSLOT_TRINKET1 or slotId == INVSLOT_TRINKET2 or slotId == INVSLOT_RANGED then
            slotMod = 0.3164
        elseif slotId == INVSLOT_MAINHAND or slotId == INVSLOT_OFFHAND then
            slotMod = 1.0
        else
            slotMod = 1.0
        end
    end

    -- Select formula based on item level
    local formula
    if itemLevel > 120 then
        formula = GS_Formula_A[quality]
    else
        formula = GS_Formula_B[quality]
    end

    -- If no formula for this quality, skip
    if not formula then return 0 end

    local A, B = formula.A, formula.B

    -- Calculate score using TacoTip formula
    local score = math.floor(((itemLevel - A) / B) * slotMod * 1.8618)

    return math.max(0, score)
end

-- Calculate total GearScore for a unit
function addon:CalculateGearScore(unit)
    if not unit or not UnitExists(unit) then
        return nil, "Unit does not exist"
    end

    -- Try TacoTip first if available
    if hasTacoTip or CheckForTacoTip() then
        local gs, avgIlvl = TT_GS:GetScore(unit)
        if gs and gs > 0 then
            return gs, avgIlvl or 0
        end
    end

    -- Fallback to built-in calculation
    local totalScore = 0
    local itemCount = 0
    local hasTwoHand = false

    -- Check main hand for 2H weapon first
    local mainHandLink = GetInventoryItemLink(unit, INVSLOT_MAINHAND)
    if mainHandLink then
        local _, _, _, _, _, _, _, _, itemEquipLoc = GetItemInfo(mainHandLink)
        if itemEquipLoc == "INVTYPE_2HWEAPON" then
            hasTwoHand = true
        end
    end

    -- Calculate score for each slot
    for _, slotId in ipairs(EQUIPMENT_SLOTS) do
        local itemLink = GetInventoryItemLink(unit, slotId)

        -- Skip offhand if using 2H weapon (already counted in main hand modifier)
        if slotId == INVSLOT_OFFHAND and hasTwoHand then
            -- Don't count offhand for 2H users
        elseif itemLink then
            local score = CalculateItemScore(itemLink, slotId)
            totalScore = totalScore + score
            itemCount = itemCount + 1
        end
    end

    return totalScore, itemCount
end

-- Calculate GearScore from cached item links
function addon:CalculateGearScoreFromItems(items)
    if not items then return 0, 0 end

    local totalScore = 0
    local itemCount = 0
    local hasTwoHand = false

    -- Check main hand for 2H
    if items[INVSLOT_MAINHAND] then
        local _, _, _, _, _, _, _, _, itemEquipLoc = GetItemInfo(items[INVSLOT_MAINHAND])
        if itemEquipLoc == "INVTYPE_2HWEAPON" then
            hasTwoHand = true
        end
    end

    for slotId, itemLink in pairs(items) do
        if slotId == INVSLOT_OFFHAND and hasTwoHand then
            -- Skip offhand for 2H users
        else
            local score = 0
            -- Try TacoTip's item score function if available
            if hasTacoTip and TT_GS.GetItemScore then
                score = TT_GS:GetItemScore(itemLink) or 0
            else
                score = CalculateItemScore(itemLink, slotId)
            end
            totalScore = totalScore + score
            itemCount = itemCount + 1
        end
    end

    return totalScore, itemCount
end

-- Get GearScore color based on score value (TBC scale)
function addon:GetGearScoreColor(score)
    if not score or score <= 0 then
        return 0.5, 0.5, 0.5  -- Grey for unknown
    elseif score < 200 then
        return 0.6, 0.6, 0.6  -- Grey for very low
    elseif score < 400 then
        return 0.0, 1.0, 0.0  -- Green
    elseif score < 600 then
        return 0.0, 0.5, 1.0  -- Blue
    elseif score < 800 then
        return 0.6, 0.2, 0.9  -- Purple
    elseif score < 1000 then
        return 1.0, 0.5, 0.0  -- Orange
    else
        return 1.0, 0.0, 0.0  -- Red for exceptional
    end
end

-- Get GearScore color as hex string
function addon:GetGearScoreColorHex(score)
    local r, g, b = self:GetGearScoreColor(score)
    return string.format("%02x%02x%02x", r*255, g*255, b*255)
end

-- Get GearScore rating text (TBC scale)
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
