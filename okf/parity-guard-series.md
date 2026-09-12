---
type: architecture
status: draft
sources:
  - id: governance
    resource: ../Tools/PARITY_GOVERNANCE.md
  - id: harness
    resource: ../Tools/PARITY_HARNESS.md
  - id: pr1
    resource: https://github.com/ryanbr/noop/pull/1534
---

# Parity guard PR series

PR1 supplies the product-free Swift/Kotlin inventory, compact authority and
baseline, typed debt dispositions, and exact-base ledger/ratchet checks.
Product-source CI enforcement is explicitly deferred to the final stack PR.[^governance]
The PR1 change is merged as PR 1534.[^pr1]

PR2 is being prepared locally as the portable case layer: deterministic case
specification expansion, one authoritative shard/operation registry, exact
split/remerge, input-bound output comparison, and independent mutant checks on
both Python demonstration sides. Shared cases now require literal expected
results and an explicit suite version bound into each case digest. One platform's
artifact can be validated independently without the other build or result file;
artifact-only comparison additionally checks both oracles and agreement. Full
source-revision metadata must match the caller's explicit expected immutable
revision. This checks consistency, not build attestation.[^harness]

The target is shared maintenance of platform-independent behavioral cases;
platform-specific UI, OS and integration tests remain native. PR2 does not migrate
or delete existing native cases. PR3 should add the native adapters and migrate a
small real algorithm's cases from both suites, preserving their assertions before
removing proven-redundant native cases. PR4 adds product-source enforcement.
Literal oracles catch agreeing-but-wrong results, but correctness still depends
on oracle quality and coverage.[^harness]

Native Swift/Kotlin adapters, bulk corpora,
product changes and enforcement remain later-series work. Python demonstration
agreement is not evidence of native platform parity.

The prepared encoding contract distinguishes booleans, integer/float spelling
and signed zero recursively. Canonical UTF-8 JSONL requires LF delimiters and
Unicode scalar strings. Governance self-tests include the portable layer and
case-spec path triggers. This document records PR2 scope; it does not claim native parity or a PR2 merge.

[^governance]: [Merged parity governance documentation](../Tools/PARITY_GOVERNANCE.md).
[^pr1]: [PR 1534](https://github.com/ryanbr/noop/pull/1534); GitHub records this PR as merged.

[^harness]: [Portable shared-case contract](../Tools/PARITY_HARNESS.md).
