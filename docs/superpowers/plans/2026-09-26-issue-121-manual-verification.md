# Issue 121 native verification handoff

The running app and its installed bundle are not changed during development. Automated
results and build provenance are recorded in the final implementation report. The checks
below require the owner's native session and are deliberately **not marked passed by
HTML screenshots or offscreen tests**. Use a development build, whose Settings version
row includes a commit marker and whose automatic release checking is disabled.

## First launch and comparison

- [ ] Confirm Settings General shows the expected development commit.
- [ ] Compare both percentages with the same-cycle Cursor dashboard. Other is the outer
  ring and Cursor the center by default. The old included-dollar limit does not define
  either region.
- [ ] A first valid response establishes jump baselines; it does not produce a Bold
  consumption jump. A not-yet-delivered already-exceeded threshold may alert once.
- [ ] Both regions remain visible if paid spending exists. Actual on-demand spending is
  separately labeled, and no cap is represented as an invented percentage.

## Menu bar, hover and popover

- [ ] Hover shows both names/percentages without adding a permanent text width. Amounts
  and inferred limits are labeled appropriately, with their own snapshot freshness.
- [ ] Hover does not steal focus or intercept a click. Both mouse buttons retain the
  same popover toggle; outside click and another system status menu dismiss it.
- [ ] Swap outer placement in Display. The other region moves to center, but usage,
  targets, thresholds and alert history do not change.
- [ ] Check light/dark appearance, different display scale, small/zero/missing values,
  VoiceOver description and keyboard access. Missing is not presented as zero.
- [ ] Check whether the popover “Included usage” section heading is clear without a
  total beside it. Included dollars remain in hover and Summary; there is no combined
  split-plan percentage. This is a nonblocking final-review UX observation.
- [ ] Keep Settings open while refreshing; current values and amount state update.
- [ ] If a pool is supplied only by current-period enrichment, hover/AX identifies that
  source and its own time. It does not cause a late jump or threshold notification.
- [ ] Check the largest popover: both pools, paid/Bot, weekly chart, stale/error and
  update rows. Scrollable content does not hide Dashboard/Settings/Log Out/Update/Quit.
- [ ] Reset countdown refreshes when reopening and its tooltip has the local absolute
  reset date. Cmd+, opens Settings and closes the popover.

## Settings compatibility

- [ ] General startup/refresh/version behavior remains unchanged.
- [ ] Both Classic and Dollar emoji styles remain selectable; Quiet/Normal/Bold are
  retained. Existing weekly metric/Today-style preferences remain available.
- [ ] Split uses effective icon-only but retains the saved legacy None/Ratio/Percent
  preference. If a legacy account is available, verify its prior selection returns.
- [ ] Alerts retain custom warning/critical and app-status preferences. Each pool and
  eligible paid budget has a separate target; ring placement is independent.
- [ ] Usage Summary is for the cycle; Recent is still the latest 30 rows, with original
  timezone, cache timestamp, loading/error and refresh behavior. Switching subviews
  does not initiate another fetch.
- [ ] Refresh amounts reports its own pending/cooldown state; normal refresh remains
  usable and does not wait for the full history scan.

## Alerts during ordinary use

Do not manufacture real spend just to reach a threshold. Boundary/race cases are covered
by synthetic automated fixtures; the owner can verify delivery during normal activity.

- [ ] Bold still reports an eligible +$0.30 included total increase even when pool pp
  changes are small. A +$0.05 tier-1 effect does not imply a system banner.
- [ ] With threshold alerts off and Bold on, an eligible tier-2 jump can still notify.
- [ ] Unattributed aggregate dollars are called Included Usage, not assigned to whichever
  region is outside. There is no guessed Max-mode cause.
- [ ] Both glyph styles restore the latest C icon after 6/15 seconds. New values,
  placement and tooltip/AX remain current while the temporary glyph is showing.
- [ ] Disabling effects while a glyph is active restores the current icon immediately.
- [ ] Simultaneous eligible threshold and Bold events produce one coherent banner.
- [ ] Relaunch within the same account/cycle does not replay a successfully delivered
  threshold. Clicking a usage notification opens the current popover.
- [ ] Closing the lid during an amount scan does not leave automatic collection paused
  for the billing cycle after wake. A real hard collection limit explains the automatic
  pause and keeps manual retry available after cooldown.
- [ ] Wake or reconnect does not claim accumulated split usage was a new immediate jump;
  a fresh not-yet-delivered current threshold can still notify once.

## Failure, identity and privacy

- [ ] A monthly-history error leaves valid percentages usable and marks only amount
  evidence unavailable/stale; it does not request a new login.
- [ ] Logout clears visible usage and stops pending effects/amount work. User preferences
  remain. The IDE does not silently log the user back in after explicit logout.
- [ ] A deliberately selected different account never receives old pool amounts,
  inferred limits, jump baselines or notification state.
- [ ] Existing IDE-first connection and opt-in browser flow still work; do not change
  credentials just to exercise a synthetic test case.
- [ ] Any screenshot intended for the repository must use Demo User or crop identity.
  Never publish actual account balances, email, raw history or private audit captures.

## Feedback format

For a discrepancy, record the development commit, surface, setting, expected vs actual
behavior, and relevant source timestamp. Keep actual financial/account screenshots in
private local notes. The owner decides when native validation is sufficient to merge
or release; development completion does not automatically merge or publish a release.
