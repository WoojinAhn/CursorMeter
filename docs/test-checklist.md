# Manual Test Checklist

Run through these scenarios after each feature change or before release.

## Authentication Flow

- [ ] First launch → menu shows "Log In..." button
- [ ] Click "Log In..." → login window opens at cursor.com/dashboard
- [ ] WebView only loads whitelisted domains (try clicking external links)
- [ ] Complete login → usage data appears in menu
- [ ] Quit and relaunch → session restored from Keychain (no re-login needed)

## Usage Display

- [ ] Usage count matches Cursor dashboard (cursor.com/dashboard?tab=usage)
- [ ] Percentage calculation correct (requests / limit * 100)
- [ ] Reset date text accurate ("Resets in N days" / "Resets tomorrow" / "Resets today")

## Refresh

- [ ] Auto-refresh fires at configured interval
- [ ] Manual refresh updates data
- [ ] Rapid refresh clicks don't cause duplicate requests

## Error Handling

- [ ] Disable network → error message shown
- [ ] Session expired (401) → prompts re-login, clears Keychain
- [ ] Access denied (403) → shows "subscription may be inactive" message

## Logout

- [ ] Click "Log Out" → returns to logged-out state
- [ ] After logout, relaunch → does NOT auto-login (Keychain cleared)

## Menu Bar Icon (#1)

- [ ] Circular progress ring displayed in menu bar (not the old chart.bar.fill)
- [ ] Empty gray ring when not logged in or loading
- [ ] Green ring when usage < 70%
- [ ] Yellow ring when usage 70–89%
- [ ] Red ring when usage ≥ 90%
- [ ] "Show usage text" setting OFF → icon only
- [ ] "Show usage text" setting ON → "189/500" text next to icon

## Notifications (#2)

- [ ] First notification request prompts macOS permission dialog
- [ ] Warning notification at 80% (default) threshold
- [ ] Critical notification at 90% (default) threshold
- [ ] Same threshold does NOT trigger duplicate notification
- [ ] Notification not sent when disabled in settings
- [ ] Custom threshold values work (e.g., 60% / 75%)

## Settings (#3)

- [ ] Gear icon in popover opens Settings window
- [ ] Refresh interval picker persists after app restart
- [ ] Notification toggle enables/disables alerts
- [ ] Warning/Critical sliders adjust thresholds
- [ ] "Show usage text" toggle updates menu bar immediately

## Popover UI (#5)

- [ ] 4-section layout: user info / usage / settings / actions
- [ ] Inline refresh icon (↻) next to usage instead of "Refresh Now" button
- [ ] Progress bar and percentage on same row
- [ ] Progress bar color matches icon colors (green/yellow/red)
- [ ] "Open Dashboard" links to `?tab=usage`
- [ ] Timer icon (⏱) next to refresh interval picker
- [ ] Gear icon opens Settings window

## Security

- [ ] No Keychain permission prompts during normal use
- [ ] Console logs contain no emails, cookies, or tokens (check with `log stream --predicate 'subsystem == "com.cursorbar"'`)
