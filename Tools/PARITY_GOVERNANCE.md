# Parity governance

This directory contains the product-free foundation for tracking Swift/Kotlin
parity. It inventories declarations and constants, records the current accepted
debt, and prevents regeneration from accepting new debt silently.

## Local checks

Run the complete Python tool suite, then the two repository gates:

```sh
python3 -m unittest discover -s Tools -p 'test*.py'
python3 Tools/parity_ledger.py
python3 Tools/parity_ratchet.py --base origin/main --offline
```

The ledger must report no finding beyond the checked-in baseline. The ratchet
also rescans the working tree, so editing a baseline without matching current
sources fails closed. `--offline` skips only GitHub existence checks; it does
not relax syntax, schema, current-tree, or exact-base checks.

Scan errors are reported before baseline evaluation because unresolved or
malformed source evidence makes the inventory untrustworthy. In that case the
ledger ends with `Baseline not evaluated: N scan errors.`; fix the listed scan
errors before interpreting or refreshing baseline state.

For a reported debt decrease, the ledger resolves `--base` (default
`origin/main`) once to an immutable commit and proves the current identities are
a subset of that exact tree. A missing or shallow base fails closed.

The v3 twin map contains explicit source roots plus a count and SHA-256 for each
canonical semantic set. The full file/function/property/constant inventory is
derived deterministically from source; prose evidence and name-only suggestions
are not authority. A normal scan expands it and deep-checks every fingerprint.
The ratchet separately materializes and scans the exact base and current trees,
so regenerating both JSON files cannot hide a newly unpaired declaration. The ledger is
fail-closed when invoked; repository CI enforcement is intentionally deferred to the final
stack PR, alongside native execution and path-filtered ledger/ratchet invocation.

Function pairs exactly equal resolved attached source claims. File pairs derive
from those claims before constant resolution, so stale file metadata cannot
steer constant pairing. Swift selector labels disambiguate overloads. Stale,
overlapping, duplicate, or ambiguous attached-pair structure is a hard scan
error and cannot be accepted by the baseline. A claim originating in an
authority root may resolve to an exact declaration in the wider repository
reference scope; that external endpoint is hashed into the pair authority but
does not silently widen the unpaired-inventory roots.

The compact baseline stores exact-identity-set hashes grouped by rule and narrow
source scope. Every group has a review reason and provenance; no wildcard or
umbrella issue matches findings. Governance is intentionally asymmetric: new
or changed debt blocks, while a proven decrease is green with a concise warning.
No JSON regeneration or disposition cleanup is required merely to land an
improvement.

This PR is the governance foundation and executable demo. Its Python self-tests
run in a dedicated workflow when the governance implementation, authority,
tests, or workflow changes. Ordinary product-source and documentation changes
do not repeatedly self-test the scanner. The workflow does **not** invoke the
ledger or ratchet as a product-source gate yet. PR2 adds the portable case layer,
PR3 adds corpora and native runners, and PR4 wires product parity/differential
checks into required CI.
When PR4 wires this gate into CI, that invocation must omit
`--offline`. Every governed `issue` field must use the exact
`owner/repository#number` form. Online validation derives the API path from
that value and verifies both the repository and issue number; pull requests do
not satisfy an issue reference. A new experimental disposition additionally needs its
own fresh issue, a specific reason, and this marker in the issue body:

```text
parity-governance-identity-sha256: <the disposition's identity_sha256>
```

Issues cannot be reused across dispositions, and `bhelm/noop#17` is explicitly
forbidden as an umbrella.

## Updating the inventory

Initial creation is deliberately one-shot:

```sh
python3 Tools/parity_ledger.py --bootstrap-map --write-baseline
```

The two bootstrap flags are inseparable. Both snapshots are computed and
validated before either is published; a scan or publication failure leaves
both prior files byte-for-byte unchanged (or both absent on first creation).

Once authority exists, refresh derived snapshots only through the guarded flow:

```sh
python3 Tools/parity_ledger.py --refresh-derived --base origin/main
python3 Tools/parity_ledger.py
python3 Tools/parity_ratchet.py --base origin/main --offline
```

Generation computes state; it never approves it. Refresh writes candidates,
runs the identity-set ratchet against the exact base, and restores both snapshots
on failure. There is no accept/force switch, and the generator never creates or
edits `parity_dispositions.json`.

For a new one-sided declaration, choose explicitly:

1. Implement and test its Swift/Kotlin twin (required for shared bug fixes and
   final shared features).
2. Manually add an `experimental` disposition with exact identity/platform,
   reason, fresh issue, and expiry date.
3. Manually add a durable `platform_specific` disposition with exact
   identity/platform and a concrete platform rationale.

These are the only disposition types. They cannot waive removal/retargeting of
an existing twin, a shared bug fix, or a final shared feature. The central typed
registry is manually reviewed; regeneration cannot populate it. A disposition
whose debt disappears emits a warning and may be removed later, but it never
authorizes reintroduction against the current merge base. Debt reductions pass
with a warning even when totals fall while another new identity remains
blocking.
Do not preserve stale findings or freeze commit hashes in tests; repository
consistency is proved by independent rescanning and canonical set hashes.

## Layer boundary

This foundation has no module runner, case corpus, coverage report, Gradle,
SwiftPM, governance-gate workflow invocation, or native-test dependency. The
path-filtered parity workflow only discovers the Python self-tests and protects
their count. Later layers can consume the inventory without making this scanner
depend on their orchestration.
