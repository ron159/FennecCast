# Task List: local-data

## Task 1: Dependency and schema

- [x] Pin GRDB 7.11.1 and add `LocalData` targets.
- [x] Add schema and device-identity tests, then observe RED.
- [x] Implement ordered migration and database factories.
- [x] Verify all nine tables, singleton cursor defaults and device mismatch rejection.

## Task 2: Local atomic mutations

- [x] Add subscription, playback, queue and sequence tests, then observe RED.
- [x] Implement business state persistence and Outbox encoding in one transaction.
- [x] Force an Outbox insertion failure and prove complete rollback.
- [x] Verify local mutation reads return versioned states.

## Task 3: Remote apply and cursor

- [x] Add pending batch and response-application tests, then observe RED.
- [x] Implement ordered pending reads with the 500-item limit.
- [x] Implement conflict-aware remote apply, cursor advancement and Outbox acknowledgement.
- [x] Verify cursor regression/order rejection and monotonic local sequence after cleanup.

## Task 4: Aliases

- [x] Add alias chain, idempotency, conflict and cycle tests, then observe RED.
- [x] Implement alias insertion and canonical resolution.
- [x] Pass focused alias tests.

## Task 5: Integration and closeout

- [x] Link `LocalData` to the FennecCast app target.
- [x] Run all package tests and strict format lint.
- [x] Run generic iOS build and build-for-testing.
- [x] Run diff, secret, schema and adjacent-checkout audits; record evidence.
