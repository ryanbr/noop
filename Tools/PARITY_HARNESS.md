# Shared parity cases and independent validation

PR2 provides the portable test contract for the parity guard series. A shared
case is written once with its inputs and literal expected result. Each platform
can eventually execute those same cases and validate its own output independently;
a later artifact-only comparison additionally checks platform agreement.

## Relationship to PR1 and existing native tests

PR1 inventories Swift/Kotlin counterparts and protects the static parity debt
baseline with ledger/ratchet checks. It does not execute both implementations.
PR2 adds case specifications, canonical transport, splitting/remerging, standalone
expected-result validation, provenance checks, and a differential comparator.
It leaves PR1's rules in place.

The target is to share **platform-independent behavioral cases**, such as
algorithm inputs and expected scores. Native UI, permissions, Bluetooth-stack
and OS-integration tests remain platform-specific. Existing native tests stay
in place in PR2: no native test has been migrated or deleted.

Both platforms agreeing is insufficient: they can share a bug. Every case in
this contract therefore requires a checked-in `expected` value. Validation
compares actual output against that literal oracle, never against a dynamically
generated reference answer. Positive comparison validates both sides against the
oracle as well as each other, so agreeing-but-wrong results fail. Oracle quality
still depends on correct domain expectations and suitable case coverage.

| Layer | Scope |
| --- | --- |
| PR1, merged | Static inventory, debt governance and ledger/ratchet tools |
| PR2 | Shared cases/oracles, portable artifact contracts and tool self-tests |
| PR3 | Native Swift/Kotlin runners and the first migration of existing algorithm cases; broader test data |
| PR4 | Product-source CI enforcement |

PR3 should start with a small real algorithm, collect relevant cases from both
native test suites, preserve their assertions as common expectations, and prove
that both adapters execute them. Remove redundant native cases only after their
previous checks are demonstrably covered. Continue migrating shared behavior
incrementally; platform-internal tests stay native.

## Independent builds and later comparison

An Android job needs only the shared cases and Android implementation. Its
standalone expected-result check needs only those cases and its own result file.
A Swift job can independently do the same on macOS. Neither needs the other
platform's build or artifact to pass its own behavioral tests. Once both artifacts
exist, a separate comparator can consume them without rebuilding either platform.

PR2 includes only two Python implementations of a small clamp demonstration,
called `core` and `reference`. These exercise the contract and negative controls;
they do not execute Android or Swift product code or establish native parity.
The validator accepts an explicit side label (for example `android` or `swift`),
and the comparator accepts explicit labels for both artifacts. This prepares the
interface; it does not supply native runners or native CI orchestration.

## Case and provenance contract

- The specification requires integer `schemaVersion: 1` and a nonblank string
  `suiteVersion`, identifying the suite revision. Update the suite version when
  changing the shared cases or their intended behavior. This is separate from the
  schema version and the product source revision.
- Each case requires `id`, `args` and literal `expected`. The registry in
  `parity_shards.py` is the sole ordered shard/operation authority.
- Expanded input records contain `args`, `expected`, `function`, `id`, `shard`,
  `suiteVersion` and `caseSha256`. SHA-256 covers the canonical record excluding
  `caseSha256` itself, including its expected result and suite version. All rows
  of one input artifact must have the same suite version.
- Output records contain `caseSha256`, `function`, `id`, `mutant`, `side`,
  `sourceRevision`, `suiteVersion` and `value`. Every row must match the exact
  input identity, function, digest and suite version. Missing, duplicated,
  unexpected or reordered rows fail closed.
- Runners must supply `sourceRevision`. Every validation, comparison and mutant
  verification requires an explicit `--expected-revision`: the intended full
  lowercase Git object ID (40 hex digits for SHA-1 or 64 for SHA-256). Every output
  row must carry that exact revision. Moving branch names, abbreviated revisions,
  mixed revisions, and artifacts from a different revision are rejected.

The expected revision must come from the caller's intended build/job context,
not be copied from an untrusted result just to make the check pass. The harness
checks metadata consistency; it does **not** attest which code actually ran,
verify a clean checkout, or authenticate artifact producers. Trusted build and
artifact provenance are responsibilities of the later native CI integration.
The source revision is not embedded in persistent cases: the same checked-in
behavioral cases can be reused across product-code changes. Case hashes detect
changed content even if someone forgets to bump the suite version.

## Run the Python demonstration

From the repository root, use the revision intended for this demonstration:

```sh
parity_revision=$(git rev-parse HEAD)
python3 Tools/parity_harness.py expand \
  Tools/parity_case_specs/core_reference.json /tmp/parity-cases.jsonl
python3 Tools/parity_harness.py run core \
  /tmp/parity-cases.jsonl /tmp/parity-core.jsonl \
  --source-revision "$parity_revision"
python3 Tools/parity_harness.py validate core \
  /tmp/parity-cases.jsonl /tmp/parity-core.jsonl \
  --expected-revision "$parity_revision"
```

The standalone validation above is complete with no reference artifact. Later:

```sh
python3 Tools/parity_harness.py run reference \
  /tmp/parity-cases.jsonl /tmp/parity-reference.jsonl \
  --source-revision "$parity_revision"
python3 Tools/parity_harness.py compare \
  /tmp/parity-cases.jsonl /tmp/parity-core.jsonl /tmp/parity-reference.jsonl \
  --expected-revision "$parity_revision"
```

For future native artifacts, the same interfaces are:

```sh
python3 Tools/parity_harness.py validate android cases.jsonl android.jsonl \
  --expected-revision "$parity_revision"
python3 Tools/parity_harness.py validate swift cases.jsonl swift.jsonl \
  --expected-revision "$parity_revision"
python3 Tools/parity_harness.py compare cases.jsonl android.jsonl swift.jsonl \
  --core-side android --reference-side swift \
  --expected-revision "$parity_revision"
```

These commands validate already-produced artifacts; PR2 cannot yet produce those
native files. Both comparison sides must have distinct labels. Successful checks
return 0, value/oracle differences return 1, and malformed contracts or provenance
mismatches return 2. `EXPECTED` diagnostics identify oracle failures; `DIFF`
diagnostics identify platform differences. Agreement does not suppress oracle failures.

## Transport and negative controls

`split` writes one canonical file per registered shard; `merge` requires the
original expanded input and proves an exact remerge. Shard parts must appear once
each in registry order, with canonical row order. Empty, unknown, duplicate,
missing or changed cases are rejected. Splitting refuses unexpected JSONL files
in the destination before writing.

Canonical JSON uses UTF-8 Unicode scalar values, sorted object keys, compact
separators, finite floats and signed 64-bit integers. JSONL uses LF only, exactly
one record per line and a final LF; CRLF and blank lines are rejected. Unicode
line/paragraph separators inside strings remain ordinary string content.
Comparison uses exact canonical JSON at every nesting level: booleans, integers
and floats remain distinct, and `-0.0` differs from `0.0`. Float spelling follows
Python's standard JSON encoder; future native adapters must match this contract.
The representative clamp retains the input value (including its number type and
signed zero) when it equals either bound.

The demonstration `run --mutant` deliberately changes the returned value.
Positive validation/comparison rejects mutant metadata. `verify-mutant` requires
an explicit expected revision, mutant metadata on exactly the named side, a normal
side matching the literal oracle, and every supplied mutant case differing from
that normal result. Controls exist for both sides.

The existing parity-governance CI discovers these tool self-tests and triggers
on case-spec changes. It adds no native build dependency or product-source parity
enforcement. Additional modules, native runners, bulk corpora and enforcement
remain the later series layers described above.
