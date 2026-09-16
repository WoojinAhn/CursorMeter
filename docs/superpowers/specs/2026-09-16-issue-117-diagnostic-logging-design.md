# Issue #117 — Diagnostic Logging Before Crash Reporting

**Date:** 2026-09-16
**Status:** Storage direction approved on 2026-09-16; recording defaults, retention, capacity, and write policy remain under design.
**Issue:** [#117](https://github.com/WoojinAhn/CursorMeter/issues/117)
**Blocks:** [#42](https://github.com/WoojinAhn/CursorMeter/issues/42)
**Dependent design:** [Crash reporting](2026-09-16-issue-42-crash-reporting-design.md)

## Objective

Preserve enough of CursorMeter's activity before a crash to explain the
failing sequence after relaunch. A crash stack identifies the failure site;
diagnostic events provide context about operations, errors, and state changes.
Neither guarantees a reproduction or a fix.

The user requested logging design before proceeding with the reporting
feature. Local recording and external submission are separate actions:
Formspree submission still requires preview and an explicit Send action.
No production implementation, logging configuration change, or test
submission is authorized by this draft alone.

## Current implementation: verified facts

- `Sources/CursorMeter/LogRedactor.swift` exposes `Log.info` and `Log.error`,
  writing strings to OSLog subsystem `com.cursormeter`, category `general`.
  There is no application-owned log file or previous-session export facility.
- Call sites cover refresh outcomes, authentication fallback/session expiry,
  weekly-data fallback, login, notifications, updates, and a watcher failure.
  They do not establish a common operation identifier or paired lifecycle.
- `UsageViewModel.refresh()` logs "Usage data refreshed" before awaiting
  weekly data and notifications. It is not a whole-operation completion event.
  Some supplementary request failures are tolerated with `try?`; the journal
  must distinguish partial success, HTTP success, and decoding success.
- `AppDelegate` creates `UsageViewModel` during property initialization.
  Capturing initialization failures requires starting diagnostic recording
  before delegate creation, not only in `applicationDidFinishLaunching`.
  Report discovery and presentation can still occur after UI setup.
- Some call sites interpolate `Error` or `localizedDescription`. Notification
  text and navigation hosts also appear in existing messages. Copying every
  existing log string into a new report is not a safe export policy.
- Existing redaction handles email and several credential patterns. It does
  not establish an allowlist for paths, names, device IDs, or arbitrary errors.
- The release packaging script does not enable App Sandbox. Restrictions on
  sandboxed apps must not be presented as proof that this app cannot query
  the system log. Access still needs validation under intended user accounts.

## Platform findings and limits

Apple documents info messages as normally memory-resident; selected messages
can be persisted under collection/error/fault conditions. Notice and error
messages are persisted subject to system quotas. Existing info-level activity
therefore cannot be assumed to form a complete durable history.

The current-process OSLogStore scope does not retrieve an earlier process's
history. System scope is a separate option on macOS; availability and useful
retention must be tested for this distributed app and ordinary user accounts.
Do not require elevated privileges or install a system logging profile as
part of routine reporting.

These are documentation/code findings. No real user logs were inspected and
no local experiment has established retrieval or persistence guarantees.

## Storage decision and alternatives

| Approach | Benefit | Cost / missing guarantee |
|---|---|---|
| Existing OSLog, with selected diagnostic events at notice/error level | Reuses system logging and avoids a custom file writer | Retention is controlled by macOS; previous-process access and completeness require verification |
| OSLog plus a bounded local event journal | Application controls event schema, retention, and previous-launch retrieval | Requires rotation, write ordering, failure handling, and measured I/O cost |
| Memory-only event buffer | Avoids persistent local diagnostic files | Loses the very history needed after a crash; does not meet the objective |

The user selected the bounded journal for reportable events while retaining
OSLog for Console diagnostics on 2026-09-16. It records a small set of
meaningful events, not every method or UI redraw. The alternatives above
record the rationale; the storage choice does not need to be reopened.

## Proposed event contract

Each event has a fixed event name, timestamp, process-run ID, ordered sequence
number, and a small set of typed, allowlisted fields. Add an operation ID for
work with a start/end pair and child requests. Run and operation IDs are
ephemeral diagnostic identifiers, not account or installation identifiers.
Use monotonic elapsed time for durations; wall time alone cannot order events
reliably when the system clock changes.

| Group | Examples of events | Useful allowed fields |
|---|---|---|
| Application | launch, ready, normal shutdown requested | App build, OS version, architecture, run ID |
| Usage refresh | start, success, partial failure, failure | Trigger enum, operation ID, elapsed time, component outcome enums |
| API boundary | request start/end | Endpoint enum, parent operation ID, HTTP status, typed network/decoding failure category |
| Authentication | source selected, fallback, session expired, logout | Source and reason enums; no account or credential value |
| Weekly data | discovery, cache invalidation, rejected shape | Strategy enum, status/reason, parent operation ID |
| UI and integrations | popover/settings lifecycle, notification outcome, watcher activation failure | Surface/action enum, outcome enum, numeric error code when meaningful |

Keep this vocabulary tied to actual diagnosis scenarios. For example:
`refresh.started → request.failed(401) → auth.fallback → request.started`
explains a different path from a decode failure after a successful response.
Pairing started/completed events can show unfinished work, but is not proof
that the unfinished operation caused the crash.

Never record tokens, cookies, request/response bodies, arbitrary URLs,
user names/emails, account/team identifiers, local paths, billing figures,
Cursor source code/prompts, or unfiltered error descriptions. Normalize
errors into known categories/codes at the event source. Sanitization happens
before persistence, with another validation pass when preparing a report.
Do not implement the journal by blindly mirroring `Log.info(String)`.

## Decisions to resolve in order

1. Decide whether local recording is enabled by default or explicitly opted
   into. Opt-in recording cannot recover a crash that preceded activation.
2. Choose retention and disk budget from the event rate and diagnostic window;
   do not copy the report draft's seven-day or 32 KiB proposal without analysis.
3. Choose write/flush behavior by measuring the loss window and runtime cost.
   Async buffering can lose tail events; synchronous writes can delay callers.
   An ordinary append is not a power-loss durability guarantee. No crash-time
   flushing or signal-handler logging is assumed.
4. Define how a crash maps to its process-run journal, including app upgrades,
   missing logs, clock changes, and relaunches. Reports must label incomplete
   history instead of attaching unrelated activity silently.
5. Allocate the external report budget between stack, event history, and the
   approved optional user explanation; preserve an explicit omission count.

## Verification requirements for the selected approach

- Previous-process events remain readable after a controlled process crash
  and relaunch; quantify missing tail events separately from parsing success.
- Concurrent operations retain correlation, and report extraction selects the
  crashed run and time window rather than the newest running session.
- Retention/rotation handles long sessions, frequent launches, partial final
  records, disk exhaustion, and write failures without disrupting usage refresh.
- Sensitive-data fixtures never appear in stored or exported events; arbitrary
  new fields cannot bypass the event schema.
- Measure idle versus active refresh overhead and actual log growth against
  the current app. No unmeasured memory, latency, or storage claim is accepted.
- Automated tests use temporary paths and synthetic content. A future crash
  experiment uses an isolated test process, not the user's running app.

## References

- [Apple: Generating Log Messages](https://developer.apple.com/documentation/os/generating-log-messages-from-your-code)
- [Apple: OSLog info persistence](https://developer.apple.com/documentation/os/oslogtype/info)
- [Apple: OSLogStore scopes](https://developer.apple.com/documentation/oslog/oslogstore/scope)
- [Apple Developer Forums: previous-run logs and sandbox restrictions](https://developer.apple.com/forums/thread/744806)

This draft records the approved storage direction and remaining design
choices; it is not an implementation plan or a fully approved specification.
