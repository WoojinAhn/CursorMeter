# Issue 121: Added UI Copy Audit

Date: 2026-09-26
Baseline: `origin/main` at `c0225f7`; feature HEAD: `93db9f1`.
Scope: added visible copy, tooltips, accessibility values, and the current usability mock.
Status: review findings and proposed wording only. Native UI and mock are unchanged by this audit.

## Finding

The implementation exposes internal collection/provenance descriptions in ordinary
usage views. A single diagnostic summary feeds Settings Summary, status-item hover,
and accessibility values. Removing the Summary screen alone does not remove this
copy from the rest of the app. The newer mock removes most of that content, but still
adds redundant state explanations and a long estimate disclaimer.

## Native implementation compared with baseline

All paths below are relative to `Sources/CursorMeter/`.

| Location | Added copy / behavior | Disposition |
| --- | --- | --- |
| `SettingsAppearanceTabViewController.swift:206–215` | Static Usage numbers / On hover, disabled Legacy text, and explanation that the saved preference resumes on single-pool plans | Remove the static/disabled rows in split mode as already agreed. Show applicable controls. Preference preservation needs no permanent caption. |
| `SettingsAppearanceTabViewController.swift:215` | Icon colors use 70% and 90%; alert thresholds are configured separately | Remove from the main card. Keep the distinction in contextual help for the icon preview because colors and configurable alert thresholds really differ. |
| `SettingsAppearanceTabViewController.swift:265` | Bold notifications are independent of usage-alert targets and their master switch | Replace with a short explanation local to the selected Bold control, such as `Large jumps also send a notification.` Do not duplicate it in Alerts. |
| `SettingsNotificationsTabViewController.swift:115` | Four sentences about targets, paid eligibility, fresh updates, and Current period sources | Remove the permanent paragraph. Independent cards and conditional paid controls express normal behavior. If data actually cannot support alerts, show one local actionable status; do not silently promise alerts from unsupported data. |
| `SettingsNotificationsTabViewController.swift:117` | Bold jump notifications are independent; configure Bold in Display | Remove the repeated permanent explanation. Keep the behavior description at the Bold control. |
| `SettingsNotificationsTabViewController.swift:76` | Notification permission: Allowed/other enum-style status | Hide successful permission status. Show `Notifications are blocked in macOS.` with an Open Settings action only when relevant. |
| `SettingsUsageTabViewController.swift:18–31,243–299` | Summary/Recent, Cycle summary, Refresh amounts, unsupported-plan explanation | Remove with the already-agreed Summary removal; preserve the pre-existing recent-usage view. A missing split feature does not need a paragraph in a single-pool account. |
| `SplitUsageController.swift:271–284` | Amounts unavailable until split usage is verified; Paused while Mac sleeps; Refreshing percentages; Auto collection paused; Collection limit reached; Amounts unchanged | Do not promote scheduler state into ordinary UI copy. Keep a short actionable refresh state only when the user requests refresh or data is unavailable; preserve admission/rate limits internally. |
| `SplitUsagePresentation.swift:75–120` | Ready/Unavailable, source names, timestamps, snapshot comparison, coverage/events/pages, residual, attribution explanation, observed-history disclaimers | Remove diagnostic text from ordinary presentation. Keep it available internally. Use one concise stale/loading/error state where the displayed data actually requires it. |
| `MenuBarView.swift:606–612,969–976` | Repeated Outer/Center words, per-pool status suffixes and source text, multiple summary lines | Use agreed spatial markers and concise amount readings. Do not append backend state to every amount. Keep the distinction between reported percentage and attributed costs without repeatedly narrating implementation details. |
| `SplitUsagePresentation.swift:49–50`; `CursorMeterApp.swift:196–199`; `MenuBarView.swift:613` | The entire summary becomes the tooltip and accessibility value | Separate normal hover/AX content from diagnostic data. Read pool name, placement, percentage, selected amounts, and a necessary freshness qualifier once. Preserve accessible labels; do not delete accessibility information merely to reduce visible text. |
| `SplitUsagePresentation.swift:116–120,159–170` | Bot observed cycle activity, Paid observed history, disabled/unknown/residual/budget-cap suffixes | Use `Bot activity` and `Paid spending`. Hide empty irrelevant rows; retain nonzero paid spending even when future spending is disabled. Do not conflate recorded Bot cost with a confirmed invoice amount. |
| `SplitUsageAlerts.swift:207,227–234` | Threshold repeated in body; previous valid update / previous high-water wording; cannot allocate dollars to pools disclaimer | State scope, actual usage, and meaningful increase. Remove the allocation disclaimer: label aggregate increases as Included usage. Preserve correction-aware meaning when simplifying a high-water delta; do not relabel that delta as since the last refresh. |

## Residual problems in the latest mock

Path: `docs/mockup-121-usability.html`.

| Function | Current copy | Proposed treatment |
| --- | --- | --- |
| `menuHover()` | Recorded costs · provisional, always appended | Remove the blanket provisional status. It is present even when the scenario permits estimation. Show a conditional qualification only when necessary. |
| `estimateSettings()` | Two paragraphs on unofficial allowances, matching costs/percentages, spillover, revalidation, circle and alert sources | Keep the user-requested limitation notice, but shorten visible text to `Estimated from usage history, not an official limit. Appears when enough reliable data is available.` Put change/spillover details behind `About estimates` if more explanation is needed. This is feature-specific help, not a collection-details panel. |
| `displayView()` | Hover over the menu bar icon for usage details | Remove the permanent caption. The icon preview may expose contextual help. |
| `alertCard()` / `alertsView()` | Alerts off; Usage alerts are off. Your settings are saved. | Remove. The switches already communicate the state; retaining preferences is normal behavior. |
| `alertsView()` | Usage jump effects are configured in Display | Remove the permanent cross-tab explanation. Bold has its own short description in Display. |
| `newBoldPreview()` | Since the previous valid update | Replace normal-case wording with `since last refresh` or omit the interval when the title/delta is sufficient. Keep corrected-delta semantics truthful. |
| `popover()` | Recorded model costs / estimated limits; Recorded cost repeated under each amount | Prefer the amount, a single concise cost label, and the `~` marker. Explain estimate limitations at the opt-in setting. Keep one short not-ready/failed/stale status when needed. |

The authoritative spec and mock were subsequently updated for implementation: estimate
help now lives in an information popover, not the permanent paragraphs described in
the historical findings above. The final accepted UI contract supersedes proposals in
this audit where they differ.

The HTML's review rationale, scenario controls, and Korean notes outside `.native`
are review-only material. Do not mistake them for shipping app copy. Likewise,
notification-preview controls and fictional-data notices do not belong in the app.

## Existing copy that should not be blamed on this change

- General settings and the Settings tab root have no changes relative to the baseline.
- Recent usage's `Included amounts show usage value covered by your plan.` existed
  before this branch (`SettingsUsageTabViewController.swift:129`).
- The weekly metric fallback caption existed before this branch
  (`SettingsAppearanceTabViewController.swift:166`).
- `New version · connection errors` was already the App status notifications caption.
- The legacy Bold notification was shortened by removing an unsupported Max-mode guess;
  that change should be retained (`NotificationManager.swift:169`).

## Acceptance for the copy cleanup

1. Healthy split data adds no Ready, source, collection, residual, or timestamp paragraph
   to Popover, Settings, hover, or VoiceOver.
2. Turning an option off does not add prose describing the switch or saved settings.
3. A failed/stale/missing value remains identifiable; cleanup must not make old data
   look current or missing values look like zero.
4. The estimate opt-in keeps a short limitation notice, and inferred values retain `~`.
5. Bold notifications communicate aggregate versus pool scope without allocation
   disclaimers, internal validation terms, or a false delta reference.
6. Single-pool, request-based, and percentage-only users see applicable controls;
   no explanatory paragraph substitutes for hiding an irrelevant control.
7. Inspect native screenshots and compact hover/AX strings, not only Settings.

## Evidence

Reviewed `git diff origin/main` for the affected native files, exact string producers,
status-item consumers, and the current HTML functions. An independent read-only
review confirmed the shared tooltip/AX diagnostic path and unchanged baseline captions.
No app behavior was changed and no app replacement was performed for this audit.
