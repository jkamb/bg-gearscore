# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

BG-GearScore is a World of Warcraft addon for TBC Classic (Interface 20505) that tracks and displays GearScore for players in battlegrounds. It requires TacoTip as a **hard dependency** - the addon will not load if TacoTip is not installed.

## Development

This is a WoW addon with no build system. Files are loaded directly by the game client in the order specified in `BG-GearScore.toc`.

**Testing:** Install the addon folder in WoW's `Interface/AddOns/` directory and test in-game. Use `/bggs debug` to enable debug output.

**Packaging:** Uses pkgmeta.yaml for CurseForge/WoWInterface packaging. Version is set via `@project-version@` token.

## Architecture

### Module Loading Order (from TOC)
1. **Core.lua** - Event system, slash commands, utility functions. Creates the `addon` namespace shared by all modules.
2. **GearScore.lua** - Wraps TacoTip's `TT_GS:GetItemScore()` API with class-specific modifiers (Hunter weapon scaling, Titan's Grip).
3. **DataStore.lua** - SavedVariables (`BGGearScoreDB`), player cache, match history, win prediction calculations.
4. **InspectQueue.lua** - Throttled inspection system. Queues players, handles `INSPECT_READY` events, retries on incomplete data.
5. **BattlegroundTracker.lua** - BG detection, team tracking, scoreboard data aggregation, combat rating calculations.
6. **UI/** - ScoreboardFrame, HistoryFrame, MinimapButton

### Key Data Flow
1. `BattlegroundTracker` detects BG entry and triggers fast scan via TacoTip cache
2. `FastScanTacoTipCache()` instantly checks all raid members against TacoTip's cache
3. For cache misses, players are queued for inspection in `InspectQueue`
4. `ProcessInspectQueue()` tries TacoTip cache first before falling back to `NotifyInspect(unit)`
5. On `INSPECT_READY`, item links are collected and passed to `GearScore.CalculateGearScoreFromItems()`
6. Results are cached in both session cache (InspectQueue) and persistent cache (DataStore)
7. UI updates via `OnPlayerInspected` callback
8. Periodic fast scans continue checking TacoTip cache every 5 seconds

### Shared Addon Namespace
All modules receive `(addonName, addon)` and attach their functions to `addon`. Core initializes modules via `addon:Initialize*()` functions called from `ADDON_LOADED`.

### TacoTip Integration (Required Dependency)
TacoTip is **required** and the addon will not load without it. GearScore calculation uses:
- `TT_GS:GetScore(unit)` - Primary method, uses TacoTip's cache for instant results when available
- `TT_GS:GetItemScore(itemLink)` - Fallback for manual item-by-item calculation during inspections

**Fast Scanning Strategy:**
1. Try `TT_GS:GetScore(unit)` first - returns instantly if TacoTip has cached the data (no range requirement)
2. If cache miss, fall back to full inspection with `NotifyInspect(unit)` (requires 28yd range)
3. Periodic fast scans check all raid members against TacoTip's cache without inspection overhead
4. Range checks only apply to the fallback inspection path, not TacoTip cache lookups

Class-specific modifiers are applied manually when using `GetItemScore`:
- Hunter: melee weapons × 0.3164, ranged × 5.3224
- Titan's Grip: weapons × 0.5 when dual-wielding 2H

### Inspection Throttling
Server limits inspections to ~1 second intervals. The optimized queue handles this with:
- `INSPECT_THROTTLE = 0.5` seconds between inspections (reduced due to TacoTip cache optimization)
- Re-queuing to back of queue on incomplete data (up to 5 retries)
- `GetInventoryItemID()` check to detect items with missing links
- Fast-path via TacoTip cache bypasses throttle entirely
