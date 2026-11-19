# Shared subscription feature continuity (#148)

## Problem

The initial #147 integration protected the shared meter from legacy monthly
data, but applied that protection to unrelated capabilities. Native Settings on
build `8997357` disabled usage alerts, jump effects, weekly charts and Today
bar styles; Recent usage always showed an unavailable placeholder. Tests
asserted those restrictions and therefore could not detect the missing
integration. Fixing the new `premium` membership token alone did not restore
these features.

## Required behavior

| Capability | Verified input and restoration |
| --- | --- |
| Usage alerts | Fresh weekly percentage and period, with the existing warning/critical thresholds and weekly wording |
| Jump effects | Consecutive valid percentages for the same owner and week, using existing intensity/style controls |
| Recent usage | Current dashboard-v2 billing items, with product/model context and the existing Local/UTC control |
| Seven-day chart | Dashboard-v2 UTC daily aggregates, using contracted USD amounts or tokens |
| Today style | Existing outline/dim/both emphasis for the current UTC chart day |
| Monthly paid reset | Server `monthlyUsage.resetsAt`, separate from the included weekly or subscription period |
| Auto Top-up | Off for an eligible prepaid response with no configured rule; unavailable for failed/malformed reads |

Keep the accepted #147 layout: weekly outer ring, prepaid center, readings on the
right, compact billing metadata, existing chart location and action rows. Reuse
the existing settings controls. Fixed ring placement and unavailable monthly
limit estimates are intentional billing differences, not activity restrictions.
Do not invent a Today percentage overlay by dividing daily cost by an unknown
shared allowance budget.

## Data boundaries

The existing selected Cursor credential and authenticated primary identity own
all readings. Current dashboard-v2 routes at `cursor.com` returned HTTP 200 in
the same session; no separate Grok login is required. The old filtered-events
RPC returned historical records but no recent-window events and must not feed
the current shared chart. See [API_REFERENCE.md](API_REFERENCE.md) for the
verified request/response contract.

Keep primary weekly/wallet data, recent history, daily aggregates and monthly
reset independent. A failed enrichment must not clear valid credentials or
discard a healthy meter. Late results from a previous owner or credential
generation cannot publish. Reuse only the same owner's last successful result
and mark failed updates stale; do not display legacy cached rows as shared data.

Billing item prices are decimal USD values. Credit grants and adjustments have
different semantics from consumed usage and purchased prepaid credit. Missing
optional token/model fields remain missing. Do not retain account identifiers
or email fields just to render a recent row. The selected metric must drive
chart height, formatting and tooltip together. Tokens are not legacy weighted
request units.

Daily responses use UTC-midnight buckets. The shared chart must label this
boundary explicitly and use UTC for day names and Today emphasis. Legacy chart
calendar behavior remains unchanged. Server-ranked series must be selected for
the chosen metric before adding the `other` bucket, avoiding double-counting.

## Included amounts and rollover follow-up

The existing 79-point amount column remains compact. A shared included entry
with a confirmed zero contracted amount shows `Included`; paid zero remains
`$0.00`, missing amounts remain unavailable, and nonzero amounts retain the
existing precision and signed formatting. Hover and accessibility help expose
the precise reported USD amount (up to ten fractional digits). No retail-cost
estimate is substituted for an included entry. See the
[before/after mockup](mockup-148-recent-amounts.html).

Only an explicit model is appended to the product. `displayExtras.displayLabel`
can contain a person's name and is not stored or used as a model fallback.
Shared daily unavailable text identifies UTC, and an open shared popover redraws
at the earlier of the next UTC and legacy KST boundary. Legacy day semantics
remain unchanged.

Review disposition: compact currency rounding is intentional presentation;
exact-value disclosure addresses the missing detail. Strict page validation is
retained because no observed API contract supports dropping out-of-range or
conflicting duplicate records and calling the remainder a complete valid page.

## Verification

Task 1 (`201465a`) passed independent specification and quality review and
1,262 tests with zero failures. Its regressions cover same-week threshold
deduplication, owner/week changes, missing/stale readings, top-up-only changes,
permission waits and shared glyph restoration. This is source/test evidence;
the final activity integration and installed-app checks are tracked in the
[implementation plan](superpowers/plans/2026-11-19-issue-148-shared-capabilities.md).

Final acceptance must separately establish raw API contract, synthetic edge
cases, native enabled controls, installed artifact identity and actual-account
display parity. A model review or test count alone does not establish the last
two. Public screenshots use synthetic identities and billing examples.
