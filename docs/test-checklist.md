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

## Security

- [ ] No Keychain permission prompts during normal use
- [ ] Console logs contain no emails, cookies, or tokens (check with `log stream --predicate 'subsystem == "com.cursorbar"'`)
