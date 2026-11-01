# Changelog

## 1.1.0

- Accept any positive integer video duration without local 5-15 limits or clamping; all modes/resolutions retain provider-side validation. Typed ultraquality prompt enhancement forwards unchanged. Propagate provider duration rejection with original status/message/retryability and one direct start call. Reviewed upstream: @ai-sdk/heygen 3.0.10 to 3.0.14. Validation passed: node Scripts/test-packages.mjs (all 52 owning package suites and the compatibility facade); node Scripts/sdk.mjs generate --check; node --test Scripts/tests/*.test.cjs (27 passed); docs-site check and build (100 pages). Live provider calls were not run.
  Compatibility: Minor release for additive native API; existing static settings and call sites remain compatible. Updated direct dependency minimums are recorded in the manifest. Existing documented JS/framework and native product gaps remain; version-delta review does not imply full parity or live-service testing. Explicit custom authentication skips an unused credential supplier, a deliberate native callback-order adaptation.
