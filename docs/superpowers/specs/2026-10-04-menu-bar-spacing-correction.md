# Compact spacing beside menu-bar percentages

Issue: #134. Owner approved the proposed correction on October 4 after inspecting #133 in the installed app.

## Correction

Reserve the native typographic width of `99.9%`, rounded up. Expand the numeric column to the larger actual row width when needed. Returning to ordinary values restores compact width. Ordinary readings remain stable; crossing into a longer representation can resize the item.

Keep the 18 pt icon, 4 pt nominal gap, two 11 pt rows, trailing alignment, complete formatter strings, and current visibility/jump/preference rules. Preserve the full existing glyph-reference set for vertical baselines so width changes cannot move either row vertically. Settings uses the same renderer and retains its 28 pt ring.

This supersedes only the boundary-width reservation decision in section 4 and geometry criterion 6 of the [original specification](2026-10-03-menu-bar-dual-percent-design.md). Its other requirements remain unchanged. On the development Mac, ordinary image width changes 68→55 pt and the visible gap for a two-digit percentage changes about 18→5 pt. These are measured results, not hardcoded font widths.

## Verification

- Reproduce the excessive ordinary gap, then require a compact ordinary column and stable ordinary/missing/near-zero widths.
- Require longer boundary/large strings to expand, fit, and keep the same vertical baselines; retain existing trailing-alignment, raster, background-draw, jump, and integration tests.
- Run the safe full Swift suite; CI runs the two existing Keychain-writing tests that are excluded locally.
- Reuse the isolated native fixture for normal/boundary/jump/Settings captures. Refresh the affected Display screenshot without PII.
- Independent focused code review before commit, followed by exact-head CI.

No data, formatting, auth, notification, setting, dependency, or circle-design changes.
