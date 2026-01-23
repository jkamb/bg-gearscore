# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

BG-GearScore is a World of Warcraft addon for TBC Classic (Interface 20505) that tracks and displays GearScore for players in battlegrounds. It requires TacoTip as a **hard dependency** - the addon will not load if TacoTip is not installed.

## Development

This is a WoW addon with no build system. Files are loaded directly by the game client in the order specified in `BG-GearScore.toc`.

**Testing:** Install the addon folder in WoW's `Interface/AddOns/` directory and test in-game. Use `/bggs debug` to enable debug output.

**Packaging:** Uses pkgmeta.yaml for CurseForge/WoWInterface packaging. Version is set via `@project-version@` token.

**Working Documentation:** Put temporary work-in-progress documentation, analysis files, and notes in the `/docs/` directory (gitignored). Only commit documentation that should be version controlled (like CHANGELOG.md, this file, etc.) to the root directory.

## Architecture

### Module Loading Order (from TOC)
1. **Core.lua** - Event system, slash commands, utility functions. Creates the `addon` namespace shared by all modules.
2. **GearScore.lua** - Thin wrapper around TacoTip's GearScore API for color/rating helpers.
3. **DataStore.lua** - SavedVariables (`BGGearScoreDB`), player cache, match history, win prediction calculations.
4. **InspectQueue.lua** - Fast scan system using TacoTip cache, delegates inspections to LibClassicInspector.
5. **BattlegroundTracker.lua** - BG detection, team tracking, scoreboard data aggregation, combat rating calculations.
6. **UI/** - ScoreboardFrame, HistoryFrame, MinimapButton

### Key Data Flow
1. `BattlegroundTracker` detects BG entry and triggers fast scan via TacoTip cache
2. `FastScanTacoTipCache()` instantly checks all raid members against TacoTip's cache via `TT_GS:GetScore(unit)`
3. For cache misses, `QueueInspect()` uses `LibClassicInspector:DoInspect(unit)` to queue inspection
4. LibClassicInspector handles the actual inspection and updates TacoTip's cache
5. Next periodic fast scan picks up newly cached data from TacoTip
6. Results are cached in both session cache (InspectQueue) and persistent cache (DataStore)
7. UI updates via `OnPlayerInspected` callback
8. Periodic fast scans continue checking TacoTip cache every 5 seconds

### Shared Addon Namespace
All modules receive `(addonName, addon)` and attach their functions to `addon`. Core initializes modules via `addon:Initialize*()` functions called from `ADDON_LOADED`.

### TacoTip Integration (Required Dependency)
TacoTip is **required** and the addon will not load without it. We rely entirely on TacoTip's GearScore calculation:
- `TT_GS:GetScore(unit)` - Primary and **only** method for retrieving GearScore
- `TT_GS:GetQuality(score)` - Get color gradient for display
- `LibClassicInspector:DoInspect(unit)` - Queue inspections to populate TacoTip's cache

**Simplified Scanning Strategy:**
1. Try `TT_GS:GetScore(unit)` first - returns instantly if TacoTip has cached the data (no range requirement)
2. If cache miss, use `LibClassicInspector:DoInspect(unit)` to queue inspection
3. LibClassicInspector handles inspection throttling, retries, and updates TacoTip's cache
4. Periodic fast scans (every 5 seconds) check all raid members against TacoTip's cache
5. All GearScore calculation and class-specific modifiers are handled by TacoTip

**No Manual Inspection:**
We no longer handle `INSPECT_READY` events or manually calculate GearScore. TacoTip and LibClassicInspector handle all inspection complexity including:
- Inspection throttling (~1-2 second server limits)
- Range requirements (28yd for NotifyInspect)
- Item cache loading and retries
- Class-specific modifiers (Hunter weapon scaling, Titan's Grip)
- Item-by-item GearScore calculation
