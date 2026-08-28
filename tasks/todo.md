# Task List: local-data

## Task 1: Dependency and schema

- [ ] Pin GRDB 7.11.1 and add `LocalData` targets.
- [ ] Add schema and device-identity tests, then observe RED.
- [ ] Implement ordered migration and database factories.
- [ ] Verify all nine tables, singleton cursor defaults and device mismatch rejection.

## Task 2: Local atomic mutations

- [ ] Add subscription, playback, queue and sequence tests, then observe RED.
- [ ] Implement business state persistence and Outbox encoding in one transaction.
- [ ] Force an Outbox insertion failure and prove complete rollback.
- [ ] Verify local mutation reads return versioned states.

## Task 3: Remote apply and cursor

- [ ] Add pending batch and response-application tests, then observe RED.
- [ ] Implement ordered pending reads with the 500-item limit.
- [ ] Implement conflict-aware remote apply, cursor advancement and Outbox acknowledgement.
- [ ] Verify cursor regression/order rejection and monotonic local sequence after cleanup.

## Task 4: Aliases

- [ ] Add alias chain, idempotency, conflict and cycle tests, then observe RED.
- [ ] Implement alias insertion and canonical resolution.
- [ ] Pass focused alias tests.

## Task 5: Integration and closeout

- [ ] Link `LocalData` to the FennecCast app target.
- [ ] Run all package tests and strict format lint.
- [ ] Run generic iOS build and build-for-testing.
- [ ] Run diff, secret, schema and adjacent-checkout audits; record evidence.
