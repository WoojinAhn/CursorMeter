# Optional stacked menu-bar percentages

Status: Reviewed v1.0, ready for owner document review. All three models approved
draft v0.1 without blocking findings; this revision incorporates the coordinator's
adjudicated clarifications. It does not authorize application implementation.
Date: 2026-10-03.
Baseline: `origin/main` at `8c71cbb5159c9a73b6c4c73fe00b6e5a3dcb4c30`.
Owner-approved layout: A, two stacked percentages to the right of the existing circle.
Local visual reference: `docs/mockup-menu-bar-dual-percent.html` (not a release asset).

## 1. Intent and authority

Make both split-pool percentages readable without hovering or opening the popover,
while keeping CursorMeter's circle and limiting menu-bar width. The owner rejected
a horizontal pair and selected layout A, then explicitly required control from
Settings. Existing hover content may remain unchanged.

The selected layout and Settings control are owner decisions. The defaults, row
ordering, missing-data handling, sizing, and jump integration below are coordinator
design decisions for review. They are not additional owner quotations.

This feature adds an opt-in exception to the split-plan icon-only rule in the
2026-09-26 split-usage spec. With the option off, that rule still applies. Other
contracts from that spec, including account isolation and authoritative percentage
sources, remain intact.

This task delivers a specification and Grok, Gemini, and Opus reviews. It does not
implement, install, release, merge, or change a live account's settings. Register a
feature issue before subsequent application implementation, per workspace policy.

## 2. Scope

In scope:

- An independently persisted split-menu-bar percentage preference, default off.
- A compact two-row readout beside the current circle when enabled.
- Settings control and preview, immediate observation-driven updates, accessibility,
  and compatibility with usage-jump emoji replacement.
- Explicit behavior for missing data, retained snapshots, account/plan transitions,
  and existing percentage boundary formatting.

Out of scope:

- Dollar readouts, quota estimation, collection schedules, API calls, and new caches.
- Changes to the popover, hover wording, Recent usage, notifications, alert policy,
  or the current ring/center colors and their thresholds.
- Applying today's highlight to the menu bar; that remains a popover-only feature.
- Additional layouts, row labels, colored markers, a shared `%`, font preferences,
  a row-order preference, or a single-pool display redesign.
- Authentication changes, GetMe, cookie rewriting, account-identity inference, or
  unrelated fixes.

## 3. Settings contract

Add `splitMenuBarPercentagesEnabled: Bool` to the existing preference owner,
`UsageViewModel`, persisted under its own UserDefaults key with the same name.

- Missing key means `false`. Existing users see no menu-bar change after upgrade.
- Keep it separate from `menuBarDisplayMode`, `popoverValueMode`, and
  `splitOuterPool`. Do not migrate or overwrite those preferences.
- This is a device-local appearance preference, not account data. Retain it across
  logout, account changes, and temporary single-pool eligibility; never store usage
  percentages with it.
- The change takes effect immediately, without refreshing usage or restarting.

In **Settings → Display → Menu Bar**:

1. Keep the existing **Outer ring** control first.
2. Add an `NSSwitch` row labeled **Show percentages** immediately after it, using
   the same accessibility label, inside the split-only controls.
3. Extend the existing preview image to reflect the switch; keep its text legend
   as `Outer: <name>` and `Center: <name>`, without duplicate percentages.

Use the same split-control visibility predicate as today
(`splitUsage.suppressesLegacyMeter`), so checking state does not replace the control
with irrelevant legacy options. The new switch stays operable in checking state;
it changes a preference, not data availability. Hide this split-only row for legacy
plans, preserving its saved value. Existing legacy text choices continue to work.

The preview uses current presentation values, including missing-value placeholders,
and the selected outer pool. It uses the same formatter and layout renderer, always
with the circle: transient jump emojis are not shown in Settings. Avoid forcing
the combined image into the existing square
28×28 preview frame: size a proportional preview container for the new aspect
ratio. Keep the ring itself at its current 28 pt preview diameter in both modes;
the combined 22 pt canvas at that scale needs about 35 pt of container height.
Reserve that height in both modes so toggling does not jump the card vertically.
The preview follows the effective visibility predicate in section 6, rather than
showing retained numbers merely because the stored preference is on.
Keep the current legend; add no long explanatory caption, disabled row,
confirmation dialog, or extra informational popup.

## 4. Layout A

```text
              43.2%
 [split circle]
               3.0%
```

The two lines span roughly the icon height within the 22 pt canvas. There is no model
name or marker in the numeric block, and each line carries its own `%` when its
formatter supplies one.

- Upper row = the pool assigned to the **outer ring**.
- Lower row = the pool assigned to the **center**.
- Default placement therefore displays Other Models above Cursor Models.
- Changing **Outer ring** swaps both the circle assignment and the numeric order
  in the same rendering update. No independent row-order preference is introduced.
- Align the rows on their trailing edge. Use monospaced digits in the system font,
  a 10 pt initial font size, and medium weight.
- Use an 18×18 pt icon slot, centered in a 22 pt-high composition, with a 4 pt
  gap to the text block and two 11 pt line boxes. Draw text sharply at the current
  backing scale; do not upscale a previously rasterized small bitmap.
- Use the normal menu-bar label color for both lines. Preserve existing circle
  colors. Both percentages have equal visual weight.
- The status item remains a single clickable/focusable control; the numbers do
  not introduce a separate hit target, hover action, or popover.

The HTML preview demonstrates layout, not native AppKit geometry. Its CSS widths
must not become hardcoded native widths. Measure native text. Reserve a shared
numeric-column width large enough for ordinary and boundary strings including
`100.0%`, `<100.0%`, `>100.0%`, and `—`; this prevents normal usage updates from
moving adjacent menu-bar items. If a valid larger value requires additional width,
expand to fit both complete strings rather than clipping, dropping a decimal,
rounding to an integer, or capping the displayed percentage. Return to the normal
reserved width when the larger representation is no longer needed.

The coordinator chooses stable width across near-100 boundaries over saving one
glyph of normal width. Native design-machine measurement was 39.32 pt for `100.0%`
and 45.89 pt for `<100.0%`: about 6.57 pt of reserved space. This is an explicit
trade-off, not an assertion that the HTML's narrower digit reservation is identical.
The font/gap proposal yields about 68 pt of image width before status-item padding;
the installed native item width still needs verification.

Font metrics and optical offsets may be tuned during native verification without
changing row count, order, content, or the 18 pt icon slot. Any material layout
change requires returning to the owner-approved mockup decision.

Place glyphs using deliberate baselines rather than adding two attributed-string
bounding heights. On the design machine, a 10 pt medium monospaced-digit font has
a 13 pt attributed height but about 7.4 pt of visible percentage-glyph ink. This
does not prove clipping or readability; verify every supported character, including
inequality signs and the em dash, in the two line boxes at available backing scales.
The entire formatter string uses one font; do not split `%` into a smaller glyph.

## 5. Data and formatting

Derive both lines from the same current, account-scoped `SplitUsagePresentation`
used by the existing tooltip/popover. Use its ordered `pools` and each pool's
`percentText`; never use the value-mode-dependent `readoutText` or `detailText`.
Popover Dollars/Both settings and estimated-limit preferences cannot change this
menu-bar percentage block.

When a current split/checking state has no snapshot, `splitPresentation` is nil.
If the block is otherwise allowed by section 6, provide two pure presentation
placeholders (`—`, `—`) in outer/center order. Do not force-unwrap the presentation,
fabricate a snapshot or account identity, or suppress required loading placeholders
solely because the presentation factory requires a snapshot.

Reuse `UsagePercentFormatter` unchanged. Its existing honesty-at-boundaries rules
take precedence over a blanket fixed-decimal interpretation:

| Input | Display |
|------|---------|
| `0` | `0.0%` |
| `3` | `3.0%` |
| `43.2` | `43.2%` |
| Positive value below `0.1` | `<0.1%` |
| Below 100 but rounding to 100.0 | `<100.0%` |
| Exactly `100` | `100.0%` |
| Above 100 but rounding to 100.0 | `>100.0%` |
| `135.25` | `135.3%` |
| Missing, negative, or non-finite | `—` |

Do not clamp text at 100 because ring geometry clamps. Do not infer a combined
percentage, sum the pools, calculate percentages from dollars, or manufacture zero
for an unknown measurement. Do not add requests on toggle, hover, redraw, or preview.

## 6. State and lifecycle behavior

The existing controller remains the sole authority over which snapshot belongs to
the current account, scope, cycle, and credential generation. The new renderer is
a pure consumer; it must not resurrect retired values or retain its own last-known
percentages.

Define a single pure visibility predicate for the new numeric block:

```swift
enabled && authState == .loggedIn && usageData != nil
    && splitUsage.suppressesLegacyMeter
```

This ties the new block to the existing split base-image branch; it is not a fresh
profile/identity check and does not exclude the valid profile-404 mitigation path.
Use the same predicate in the Settings preview. The Settings row's visibility and
operability still follow section 3, even when the effective numeric block is hidden.

| State | Required numeric behavior when preference is on |
|-------|------------------------------------------------|
| Eligible split with both values | Render both formatted percentages. |
| Eligible split with one value missing | Render its `—`; keep the other valid value. |
| Split/checking with no usable percentage values | Under the visibility predicate, render `—` in each missing row. Existing checking normally supplies a snapshot with nil values; a nil-presentation fallback is defensive, not a claimed live failure. |
| Refresh in progress with an authorized retained snapshot | Keep the same current presentation until existing state accepts or retires it. |
| Same-owner transient failure retaining a snapshot | Keep retained values under the existing retention policy; keep hover/AX freshness semantics unchanged. |
| Existing controller clears snapshot on account/scope/cycle/generation change | Clear the numeric values in the same UI update; do not independently keep old text. |
| Login required or logged out | Omit the new percentage block even if the preference is saved; preserve the existing base-image selection path. |
| Legacy/single-pool mode | Use the existing legacy mode and text setting; no split block. |
| Preference off | Existing icon-only split rendering; no reserved blank numeric width. |

Do not infer a healthy identity merely because the split presentation exists. The
previously implemented IDE profile-404 mitigation may present successful usage;
this feature respects its existing valid usage/ownership decisions without adding
another identity gate or relaxing one.

If no authorized split presentation exists, never attach split-looking numbers to
an unrelated legacy, idle, or login image. Pure loading placeholders require the
same visibility predicate. Data eligibility, not an Ultra plan-name check, selects
this UI.

Do not claim that every transition to `loginRequired` clears the existing snapshot:
the current no-cookie branch can change auth state without a full reset. Hiding
this new block is not authorization to change legacy/base-image or tooltip policy.

## 7. Rendering and jump ownership

Current implementation draws status text into images. `JumpEffectCoordinator`
temporarily replaces `button.image`, while `CursorMeterApp.updateStatusItem()`
skips image updates during that swap. Simply appending two rows to the normal image
would lose or freeze them during a jump.

Introduce a narrow composition seam shared by normal and active-jump rendering:

- A normal split image contains the current circle in the icon slot plus optional
  percentages. An active jump replaces only that icon slot with the selected emoji
  and existing glow. The numeric block stays present and current.
- The composite width does not change merely because a jump starts or ends.
- Percentage updates, the new preference, and outer-pool changes recompose the
  current image even during a jump, without accidentally ending or extending it.
  A redraw is not a new jump event: do not invalidate or reschedule its restore
  timer. Both width and height remain stable across jump start and end.
- Existing jump tier selection, duration, glyph styles, notification policy, and
  event deduplication are unchanged.
- The active glyph/glow is transient coordinator state. Expose enough state or an
  injected render callback to compose the latest image; never cache the full
  pre-jump composite and restore stale percentages afterward.
- End/cancel/logout restores from current state. Turning percentages off during
  a jump removes the numbers immediately while preserving the still-valid effect.
- If ownership retirement clears usage while auth stays logged in and the existing
  policy leaves the effect active, clear the rows immediately and let the glyph
  continue alone in its icon slot until the original deadline. Existing auth or
  disable cancellation still takes precedence. Do not freeze the old composite.
- Preserve the existing legacy rendering behavior when this split feature is not
  effective. Do not use a newly wide text canvas as the emoji's icon dimensions.

Implementation must choose a single final-image writer per update and an acyclic
rendering dependency. Avoid making `restoreImage` and a new jump compositor call
each other. This seam is required for the selected display, not authorization for
a general jump/coordinator refactor.

## 8. Observation and accessibility

Add the persisted Boolean and any new presentation dependencies to the relevant
`CursorMeterApp` Observation tracking blocks and Settings updates. Preserve the
existing `withObservationTracking` + MainActor re-arm pattern.

Keep tooltip content and the existing `CursorMeter usage` accessibility label and
pool-named accessibility value. Do not expose two ambiguous, unlabeled AX numbers,
duplicate the existing spoken percentages, or let the glyph replacement alter the
meaning read by VoiceOver. Plain tooltip/AX text continues to name pools and
represent missing/stale values under existing rules.

Support light/dark menu-bar backgrounds and native backing scales. Re-render for
the same appearance/scale events as the current menu-bar renderer; if adding the
text exposes a missing existing redraw hook, add only the minimal hook needed for
this display. No live settings are changed by verification without installation
authorization.

## 9. Implementation boundaries

Expected areas, subject to narrow extraction if a pure helper improves testability:

| Area | Responsibility |
|------|----------------|
| `UsageViewModel.swift` | Persist the independent Boolean using existing patterns. |
| `SplitUsagePresentation.swift` / a small pure menu-bar presentation helper | Reuse ordered pool percentage strings and derive effective visibility; no new ownership rules. |
| `CircularProgressIcon.swift` / a small compositor beside it | Measure and draw icon + two lines, optionally substituting a jump glyph. |
| `CursorMeterApp.swift` | Observation, presentation selection, and current-state image wiring. |
| `JumpEffectCoordinator.swift` | Narrow active-glyph/composition integration only. |
| `SettingsAppearanceTabViewController.swift` | Switch, split-only visibility, and proportional preview. |
| Relevant tests and paired documentation | Critical state/persistence/integration regressions and user-facing option documentation. |

No new packages, SwiftUI, network calls, persistent measurement state, or account
cache are needed. Follow Swift 6 strict concurrency and existing AppKit conventions.

## 10. Verification selected before implementation

The following are implementation acceptance criteria, not claims that tests have
already run for this documentation task.

1. **Preference isolation:** fresh defaults are off; enable/disable persists across
   a new view-model instance; legacy text, popover modes, and outer-pool preferences
   are unchanged. Follow existing preference tests' save/restore pattern for the
   touched keys in the isolated test-host defaults domain, verifying it differs
   from the installed app domain. If that isolation is unavailable, use an isolated
   suite with the narrowest storage seam. Do not alter the live app's defaults or
   redesign all settings storage merely for this feature.
2. **Mapping and formatting:** both outer-pool choices produce correctly ordered
   existing formatter output, including zero, near-zero, near-100, over-100, and
   missing/invalid values. Changing popover Dollars/Both never changes these lines.
3. **State boundaries:** split/checking/legacy/login transitions, partial values,
   authorized retained snapshots, and snapshot retirement show the expected block
   or clear it. Include a same-owner degraded-profile sample and an account-change
   regression; reuse existing ownership/reset paths, not new production auth logic.
   Specifically exercise the no-cookie fixture with retained `usageData` and split
   snapshot plus login-required auth: the new rows disappear, while existing base
   image, tooltip, and accessibility selection remain unchanged.
4. **Live updates:** toggling the switch, swapping the outer pool, and accepting new
   percentages updates both status item and Settings preview without a refresh.
5. **Jump integration:** assert percentage continuity and stable layout across jump
   start → newer snapshot → outer-pool change → preference off/on → restore. Also
   verify logout/ownership retirement clears old values during an active effect,
   and existing single-pool and split-option-off jump behavior remains compatible.
   Existing coordinator tests cover pure policies, not image orchestration. Use
   the smallest injectable image-output and restoration/timing seam needed to test
   this sequence without a live `NSStatusItem` or real waiting. Compositor-only
   tests do not prove that observation callbacks actually refresh an active jump.
   Items 4–5 therefore have two proof layers: automated pure render-state/compositor
   and injected coordinator tests, plus native verification of AppDelegate's actual
   Observation wiring and status-item writes. Do not start the production app
   delegate in the SPM host just to reach its private rendering methods.
6. **Geometry:** normal and boundary strings fit; ordinary value changes preserve
   width; larger strings expand without clipping; missing rows do not collapse the
   block. Avoid tests tied to fragile exact glyph raster pixels.
7. **Native visual verification:** inspect real-size menu-bar and Settings captures
   through AX-driven automation, light/dark backgrounds and available backing
   scales; verify small-text readability, baseline alignment, no stretched preview,
   no horizontal scroll, correct click target, tooltip, and VoiceOver meaning.
   HTML screenshots alone cannot close this native check.
8. **Regression checks:** run focused tests then the required Swift suite under the
   repository's established test safety policy. Tests must not touch the real
   Keychain or notification center. Refresh affected screenshots with PII removed
   and update English/Korean user-document pairs in the same commit.
   Include the old icon-only statement in the semantic stale-reference sweep;
   link its new opt-in exception when the feature is implemented.
   Specifically check the README pair and `docs/screenshots/settings-display.png`.

## 11. Review and completion

Review this whole contract against the current source, not just the visual mockup.
Request independent Cursor reviews from live-roster Grok, Gemini, and Opus 5.5
variants; record exact requested/reported model IDs and job receipts locally.

The coordinator adjudicates findings against the code and owner decisions,
accepting actionable contradictions or missing contracts and rejecting scope
expansion. Do not equate model agreement with native verification. Material
amendments go back to reviewers; any change to the approved layout or Settings
requirement goes back to the owner.

This specification task completes when the document, model findings, and an
independent coordinator disposition are available to the owner. Implementation
planning and application changes remain a subsequent step.

### Review outcome

All three independent reviews assessed draft v0.1 against the source and returned
`APPROVE_SPEC`, with no blocking findings:

| Family | Exact requested model | Verdict |
|--------|-----------------------|---------|
| Grok | `grok-4.7-xhigh` | APPROVE_SPEC |
| Gemini | `gemini-3.8-flash-high` | APPROVE_SPEC |
| Opus | `claude-opus-5-5-max` | APPROVE_SPEC |

Astra's judgment is **approve the specification with the clarifications incorporated
here**. Native readability, geometry, and application behavior are still unverified
until implementation. Row order follows the existing outer/center mapping as an
explicit coordinator decision; do not misattribute that detail to an owner answer.

Accepted clarifications cover placeholder sourcing, effective visibility, unchanged
legend text, stable preview ring scale, event-versus-redraw timer ownership, and
test layers that can actually prove jump continuity. The extra legend wording and
narrower but boundary-jittering width alternative were not adopted. Test isolation
follows existing patterns when their domain is isolated; broad preferences refactoring
is not required. The local review synthesis records dispositions and provenance.
