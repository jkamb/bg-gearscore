# Changelog

## [1.1.0] - 2026-01-21

### Added
- Win prediction feature based on gear score, level, and map history
- Requires 10+ matches on a map before predictions are shown
- Prediction displayed on scoreboard with color-coded progress bar
- Prediction accuracy tracking in match history
- Match tooltips now show prediction vs actual result

### Formula
- Base: Historical win rate for the map
- GS Bonus: +5% per 100 GS above historical average winning GS
- Level Bonus: +3% per level advantage over enemy team
- Clamped to 5-95% range

## [1.0.0] - Initial Release

### Features
- Real-time GearScore tracking for friendly team in battlegrounds
- Automatic player inspection queue
- Live scoreboard showing player GearScores
- Match history with team statistics
- Minimap button for quick access
- Auto-show scoreboard when entering battlegrounds
