# Issue 147 consumer ledger decoding plan

## Goal and boundary

Decode the observed consumer `ListPrepaidBalanceChanges` gRPC-web contract with Foundation only. This stage establishes reliable raw evidence for the purchased-credit meter. It does not claim a working authenticated adapter, sum invoices, change account state, or connect native UI. The current CLI-proxy weekly/balance request succeeds, while a single direct consumer-ledger bearer request returned HTTP 403. Do not bypass that response or treat it as an expired Cursor session.

Source: public dashboard `0tcfdy03501jg.js`, inspected and saved via DevTools. Its embedded `grok_build_billing.proto` descriptor establishes the schema below. The live empty response was successful and included a present zero-valued total. A user-performed $5 top-up has been requested after preparing a one-time draft with automatic top-up off; payment has not been performed by the agent.

## Task 3: bounded raw ledger decoder

Owned files: `Sources/CursorMeter/GrokPrepaidLedger.swift`, `Tests/CursorMeterTests/GrokPrepaidLedgerTests.swift`. No existing API, credentials, model state, UI or shared documentation changes by the implementer.

- [x] Write critical tests first; run a compilable stub to RED.
- [x] Add immutable Sendable/Equatable raw ledger and entry types with optional signed Int64 cents, optional invoice identifiers/reference, optional validated timestamp, raw origin and optional raw status enum numbers. Keep unknown values distinguishable; no successful-status default.
- [x] Decode exactly one uncompressed gRPC-web data frame followed by a trailer with grpc-status 0. Bound input to 4 MiB; reject truncation, invalid/unsupported frame flags, repeated data/trailers, nonzero/missing status and data after trailers.
- [x] Use a private protobuf reader with bounded 64-bit varints, valid field tags, unknown-field skipping for wire types 0/1/2/5, and explicit errors for malformed input or unsupported wire types. Int64 uses two's complement, not ZigZag. Merge repeated singular embedded messages; empty later messages retain prior fields, while explicit later scalar values overwrite them.
- [x] Decode response changes=1 repeated entry and total=2 Cent. Cent.val=1 int64; present empty Cent is zero and absent Cent remains nil. Entry amount=1 Cent, invoice_id=2 optional string, invoice_reference=3 optional string, create_time=4 Timestamp, topup_status=5 optional enum, change_origin=6 enum (implicit zero). Timestamp seconds=1 int64, nanos=2 int32; malformed timestamps stay unavailable or fail decoding consistently, never invent now.
- [x] Preserve signed amounts and raw statuses; this stage performs no purchase aggregation. Avoid retaining response bodies or identifiers in logs.
- [x] Tests cover the observed empty body, a synthetic successful negative-cent purchase, automatic purchase, positive spend, present-zero vs absent amounts, unknown fields/enums, UTF-8 identifiers, missing/invalid timestamps, int64 boundaries, truncated/overflow varints, invalid lengths, compressed/error/truncated frames and gRPC trailers.
- [x] Focused GREEN, independent spec review, then independent quality review. Commit only reviewed files after regression.

Implementation evidence: the initial compilable stub produced RED: 23 tests/121 failures, then GREEN: 23/0. A subsequent protocol review identified missing embedded-message merge semantics. Three regressions produced RED: 26/4; the corrected parser passed 26/0 and independent spec re-review. Full local regression passed 1165/0 in `/tmp/cursormeter-147-ledger-all.log`. Fresh Argon High and Grok XHigh quality reviews both returned NO_BLOCKING_FINDINGS after reading both files in full. Reviewers did not execute tests. No live nonempty ledger or native provider integration is implied.

## Following integration gates

Verify the posted purchase entry, balance and status after the user's payment. Purchase total must include only succeeded PURCHASE/AUTO_PURCHASE credited amounts. Refunds, grants, manual changes and inconsistent history must retain the balance but make purchased consumption unavailable until reconciled. The descriptor has no pagination fields; the client slices 20 rows only after receiving the full returned list. Server history-retention guarantees remain undocumented.

Keep identity and transport separate from binary decoding. Scope all merged fields to one verified Grok principal/session generation. Browser cookie auth, CLI proxy auth and Cursor IDE auth must never be silently interchanged. A read-only provider transport and explicit activation path still need implementation and live verification before native delivery.
