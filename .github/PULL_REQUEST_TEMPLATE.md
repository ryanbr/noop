## What this PR does

<!-- A short description of the change and why it's needed. -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Refactor / cleanup
- [ ] Documentation
- [ ] CI / tooling

## How it was tested

<!--
For anything on the BLE path, say what you tested on real hardware and which
strap (4.0 / 5.0 / MG). For protocol or analytics changes, point to the test
that covers it. "Builds and unit tests pass" alone is not enough for BLE work.
-->

## Checklist

- [ ] Swift package tests pass for any package I touched (`swift test` in `Packages/<name>`)
- [ ] Android unit tests pass if I touched `android/` (`./gradlew testFullDebugUnitTest`; after a branch switch add `--no-build-cache --rerun-tasks`, or Gradle may fail classes you never touched)
- [ ] No new build warnings introduced
- [ ] UI changes use only `StrandDesign` tokens — no hardcoded colors, fonts, or spacing
- [ ] No hardcoded hex frame bytes; protocol facts live in the schema / decoders
- [ ] Follows the conventions in [`docs/CONTRIBUTING.md`](../docs/CONTRIBUTING.md)
- [ ] I did not commit generated output (`Strand.xcodeproj/`) or any secrets/keystores

## Related issues

<!-- Refs #N -->
