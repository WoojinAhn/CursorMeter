# Issue #42 — Crash Reports After Relaunch

**Date:** 2026-09-16
**Status:** Draft on hold while the prerequisite [logging design](2026-09-16-issue-117-diagnostic-logging-design.md) is discussed; implementation has not started.
**Issue:** [#42](https://github.com/WoojinAhn/CursorMeter/issues/42)
**Baseline:** `303a11c` (`HEAD` and fetched `origin/main` match).

## Goal and agreed direction

Let a user report a CursorMeter crash after relaunching, without configuring
a mail client, signing into GitHub, or using Cursor Agent. Reuse the crash
report written by macOS. Send diagnostic text through Formspree, which
notifies the maintainer by email.

The conversation established these constraints:

- Detect on relaunch; do not add a continuously running crash helper.
- Use text reports rather than file attachments.
- The user supplied `https://formspree.io/f/xdeknrao` as the collection endpoint.
- Prepare and review the design before implementing the feature.
- Include an optional user-written description; submission also works without it.
- Retain Swift 6, AppKit, and zero external package dependencies.

The detailed behavior below is proposed, not previously approved. In
particular, the collection window, payload budget, and prompt dismissal
policy need review as part of this draft. Execution logs will come from the
bounded application journal approved in [#117](https://github.com/WoojinAhn/CursorMeter/issues/117).

## Approaches considered

| Approach | Benefit | Cost or limitation |
|---|---|---|
| Native preview and direct HTTPS submission | No reporter account, mail setup, or browser handoff; fits AppKit | Requires native error handling and a Formspree configuration that accepts native requests |
| Browser form with copied diagnostic text | Can handle browser challenges | Adds browser/copy steps and needs a hosted form page |
| Mail composer or GitHub issue | Minimal collection infrastructure | Requires reporter setup or login; GitHub reports may be public |

Propose the native approach because it matches the agreed reporting flow.
The supplied AJAX guide describes the closest interaction model; implement
its HTTP behavior with Foundation, without adding JavaScript or a WebView.
If Formspree cannot accept native submissions under the intended plan and
settings, revisit the choice before shipping rather than silently adding a
browser fallback.

## User flow

1. Finish normal menu bar setup. Scan for recent CursorMeter crash reports
   asynchronously so reporting cannot block startup or usage refresh.
2. If an eligible, unhandled crash exists, offer its preview once. Show the
   crash date and crashed app version; do not imply the current version crashed.
   Defer presentation while a login sheet or another modal interaction is active.
3. The preview explains that the displayed diagnostic fields will go to the
   developer through Formspree. It shows every transmitted field in readable
   form and provides **Send Report** and **Don't Send** actions. No network
   submission occurs before Send Report.
4. While sending, disable duplicate submission. On confirmed acceptance,
   show a short success state. This means the service accepted the report,
   not that the developer has read it or that an email reached the inbox.
5. On failure, keep the preview with **Retry**, **Copy Report**, and **Close**.
   Do not retry automatically or require an email address.
6. Settings > General > **Report Crash…** opens the latest eligible report
   on demand, including one previously dismissed. If none is available,
   explain that and offer to open the diagnostic folder. Never fabricate a
   crash report from an unclean shutdown marker.

Closing or choosing Don't Send records that the automatic offer was handled.
A failed submission is not marked sent, but closing its window also suppresses
future automatic offers for that incident. Settings remains the retry route.
An already accepted incident shows its sent status instead of allowing a new
submission. There is no automatic resend queue or global always-send setting.

The app-owned coordinator retains an in-flight request if the report window
is closed, records confirmed acceptance, and does not reopen the window on
completion. Quitting the app may leave delivery uncertain; reopening the
manual flow preserves the submission ID and warns before a retry.

The report preview includes an optional “What were you doing when the app
crashed?” field. The user approved this choice on 2026-09-16. Leaving it
empty must not block submission. Include the entered description in the
preview of the final report, and rebuild that preview whenever it changes.
Explain briefly that code, credentials, and personal information should not
be included. Apply the report's sanitization rules to this field too, while
making no guarantee that arbitrary free text can be fully anonymized.

A contact-email field remains excluded as a proposal for review. Without a
reply address, the maintainer cannot ask that reporter follow-up questions.

## Detection and local state

- Read regular `.ips` files in the current user's
  `~/Library/Logs/DiagnosticReports/`. Do not follow symlinks or read other
  applications' reports for submission. Do not delete or modify macOS files.
- Narrow candidates by filename, then verify decoded process identity and
  bundle identifier `com.woojin.CursorMeter`. The OSLog subsystem
  `com.cursormeter` is a different identifier. A filename alone is insufficient.
- Support the macOS report envelope plus JSON payload using Apple's format
  documentation and representative fixtures. Reject malformed, mismatched,
  unsupported, or incomplete reports without interrupting normal app use.
- Proposed eligibility: crash timestamp within the last seven days and before
  the current launch. Select the newest eligible report. Older reports remain
  available through Finder; there is no backlog of automatic dialogs.
- Apply the same seven-day window on the first launch of the feature, allowing
  a recent crash of the preceding app version to be reported.
- Scan once per launch and on the Settings action. A report written after the
  startup scan is discoverable on a manual scan or the next launch. No watcher,
  helper process, or recurring polling is introduced.
- Reject files larger than 5 MiB before parsing and enforce the limit while
  reading. This is a proposed local resource bound, not an Apple format limit.
- Persist only local incident identity, a randomly generated submission ID,
  crash time, and offered/dismissed/accepted status. Use the decoded incident
  ID, with a content digest fallback, for local deduplication. Neither the
  original incident ID nor its digest is sent. Retain entries for seven days.
- Keep sanitized report text in memory for preview and retry. Do not persist
  another copy of raw reports or a crash-time credential/settings snapshot.

Missing files, unsupported reports, or denied filesystem access mean that
automatic detection is unavailable. They are not evidence of a clean run,
and an unclean exit is not proof that a macOS crash report exists.

## Diagnostic payload and privacy

Build a new allowlisted report instead of uploading the `.ips` contents.

| Include | Purpose |
|---|---|
| Optional user-written description, as shown in the final preview | Reproduction context |
| Recent sanitized diagnostic events, as defined by #117 | Operation sequence and errors before the crash |
| Schema version and random submission ID | Interpretation and manual duplicate recognition |
| Crashed app version/build and reporting app version | Distinguish the incident from the relaunch |
| Crash timestamp, macOS version, CPU architecture, translated-process flag when present | Environment and Intel/Rosetta diagnosis |
| Exception type/codes and structured termination namespace/code | Failure classification |
| Crashed thread frames: image reference, instruction offset, sanitized symbol when available | Identify the failing stack |
| Referenced image basename, UUID, architecture, load address/size when available | Later symbolication against matching binaries |
| Explicit omission/truncation indicators | Make report completeness visible |

Exclude account names/emails, credentials, request headers and bodies,
Cursor prompts/code/conversations, billing data, device identifiers,
absolute paths, environment variables, and arbitrary diagnostic strings.
Use basename-only image names and sanitize remaining string fields; an
unknown field is omitted by default. Do not use AI to summarize reports.

`LogRedactor` is an existing defense for several credential/email patterns,
but is not sufficient to sanitize a raw crash report. The builder must also
remove paths and avoid arbitrary application-specific exception text. Test
sanitization before considering its output safe for preview or transport.

Recent application diagnostic events are now part of the intended reporting
scope. The approved storage direction is existing OSLog plus a bounded
application-owned diagnostic journal (#117). Collection, persistence, privacy
rules, and matching to the crashed process are being designed in that issue.
The earlier proposal to exclude runtime logs is superseded. Do not assume
existing OSLog messages are complete, recoverable, or safe to export.

Proposed budget: the complete UTF-8 JSON request must not exceed **32 KiB**.
This preliminary stack/description allocation is not final: #117 must define
how diagnostic events share the budget before this algorithm is implemented.
Keep metadata and symbolication identifiers first; include crashed-thread
frames from the top until the budget is reached, with an omission count.
Only include images referenced by retained frames. Reserve room for an entered
description; if it prevents the report from fitting, ask the user to shorten it
rather than silently truncating their words. Never cut serialized JSON
or a UTF-8 sequence. If required metadata plus one available frame cannot fit,
do not send a misleading report; explain that the report cannot be prepared.
A crash report with no frames remains valid and explicitly says frames were
unavailable. The preview must match the final bounded payload.

This is an application budget, not a verified Formspree service limit or a
guarantee against mail-client clipping. Formspree and the mail provider can
observe network metadata such as the sender's IP; do not describe this flow
as anonymous merely because the payload excludes account identifiers.

## Transport and service setup

- Use a dedicated, injectable `URLSession` with ephemeral configuration,
  cookie handling disabled, and no Cursor authorization headers or shared
  authentication client. Use a 30-second request/resource timeout.
- POST a JSON object to the fixed HTTPS endpoint with
  `Accept: application/json` and `Content-Type: application/json`.
- Proposed fields: `subject` (CursorMeter crash and version), `message`
  (formatted diagnostic text), `report_id`, and `schema_version`.
- Omit `email`; the form must not require it. The endpoint ID is public
  configuration, not a credential. Do not embed a Formspree admin/API token.
- Refuse redirects for submissions. An HTML challenge or redirect is a
  failure, not successful delivery. Confirm the service's success JSON
  contract in integration verification before implementing response decoding.
- Map validation/configuration failures, rate/quota failures, server errors,
  and connection/timeouts to concise native messages. Never display an
  unfiltered server response that might echo submitted content.
- A timed-out request may have reached the service. State that acceptance
  could not be confirmed; a user-requested retry uses the same report ID.
  Formspree server-side deduplication is not assumed.

The form owner must verify activation, recipient delivery, optional email
validation, and compatibility with requests without browser CAPTCHA/domain
context. The endpoint was supplied by the user, but none of these properties
has been tested. No form settings were changed and no reports were submitted
while preparing this document.

A public endpoint can receive unrelated submissions and exhaust its quota;
client-side deduplication cannot prevent that. If the form requires a browser
challenge, resolve the configuration/abuse trade-off before enabling the
native integration. Never spoof browser headers to bypass its configuration.

## Integration boundaries

| Component | Responsibility and dependencies |
|---|---|
| `CrashReportStore` | Bounded filesystem scan, incident selection, and deduplication metadata; injected directory, clock, and persistence |
| `CrashReportBuilder` | Decode report data into allowlisted, sanitized, size-bounded payload; pure fixture-testable logic |
| `CrashReportClient` | Submit the prepared payload; injected session; no filesystem or Cursor credential access |
| `CrashReportCoordinator` (`@MainActor`) | Own preview/send state, presentation timing, and incident outcomes |
| `CrashReportWindowController` | AppKit preview, actions, and errors; delegates sending to the coordinator |

`AppDelegate.applicationDidFinishLaunching` starts discovery after menu bar
setup. A callback from General Settings reaches the same coordinator via
`SettingsTabViewController`. Keep reporting independent of `UsageViewModel`
and its usage refresh lifecycle. These are proposed boundaries, not a demand
for a new protocol or file for every small type.

Before native UI implementation, prepare and review the required before/after
`docs/mockup-42.html`. No layout decision is finalized by this text document.
Implementation also updates README/README.ko and SECURITY/SECURITY.ko to
describe the additional destination and exact collection behavior, and
refreshes affected Settings screenshots.

## Verification and release acceptance

Select tests before implementation and add them with the corresponding code:

1. Detection fixtures: valid ARM/Intel/Rosetta reports, previous-version crash,
   unrelated app, malformed/incomplete JSON, missing directory, oversized file,
   timestamp boundaries, newest selection, and duplicate/dismissed/accepted IDs.
2. Privacy fixtures: emails, credential-like strings, home paths, device IDs,
   unknown fields, and arbitrary exception text never survive into the payload.
3. Payload tests: preserved stack/image correspondence, explicit missing frames,
   omission counts, Unicode-safe size bounding, and exact preview/request parity.
   Cover an empty optional description, edits reflected in the preview, sensitive
   text sanitization, and a description that exceeds the remaining size budget.
4. Transport tests with `MockURLProtocol`: endpoint/method/headers, absent
   credentials/cookies/email, confirmed JSON success, validation error, rate
   limit, HTML challenge, redirect refusal, server error, timeout, and retry ID.
5. Coordinator tests: no request before Send, one request per click sequence,
   cancellation/dismissal semantics, successful deduplication, and manual retry.
6. Run the existing Swift suite and native ARM/Intel CI during implementation.
   Tests use temporary directories and isolated defaults, never real crash logs,
   Keychain, notifications, or the production Formspree endpoint.
7. With explicit test-send authorization, send synthetic normal-size and
   maximum-budget reports to the supplied form. Verify dashboard contents and
   received email against distinctive start/end markers and the full payload.
   Use no real personal logs. Record HTTP outcome separately from email receipt;
   a mail client's collapsed view must not be mistaken for lost report content.
8. Verify the native flow with a synthetic fixture and AX-based screenshots.
   Confirm normal app startup and usage refresh remain responsive; measure
   scan time on representative directory sizes without inventing an overhead claim.
9. Verify that retained release binaries or matching dSYMs can resolve a sample
   report's image UUIDs and offsets for both architectures. Preserve matching
   symbol material for future releases if existing artifacts are insufficient.
   Capturing a stack alone does not guarantee actionable symbolication.

Service configuration and payload integrity are pre-release checks, not work
already completed. This draft does not claim the new endpoint works.

## Scope exclusions

- Immediate reporting at the instant of a crash, crash signal handlers,
  a resident helper, a crash SDK, or a self-hosted collection backend.
- Automatic transmission, automatic retries, raw `.ips` uploads, unrestricted system-log
  harvesting, or optional contact information. Bounded application diagnostic
  events are covered by the prerequisite logging design.
- A guarantee that every termination produces a readable crash report or that
  the app can report a crash when it cannot relaunch successfully.
- A new GitHub issue per report, an issue-triage dashboard, or automatic replies.

## Review checkpoints

Review these proposed product choices before writing the implementation plan:

1. First iteration sends structured crash data plus the approved optional
   description and recent diagnostic events defined by the logging design; a
   reply address remains a proposed exclusion.
2. Offer the newest eligible crash from seven days, suppress that offer after
   dismissal, and keep manual reporting in General Settings.
3. Use a 32 KiB request budget and manual retries, accepting that additional
   diagnostics may be necessary for some failures.

## References

- [Apple crash-report JSON format](https://developer.apple.com/documentation/xcode/interpreting-the-json-format-of-a-crash-report)
- [Formspree AJAX integration](https://help.formspree.io/articles/building-your-form/submit-forms-with-javascript-ajax/)
- [Formspree special fields](https://help.formspree.io/articles/building-your-form/special-fields)
- [Formspree CAPTCHA configuration](https://help.formspree.io/articles/form-and-project-settings/recaptcha-settings)
- [Formspree system limits](https://help.formspree.io/articles/form-and-project-settings/system-limits)

Official documentation was consulted on 2026-09-16. A current service-wide
maximum text-field length was not established by the preceding research.
