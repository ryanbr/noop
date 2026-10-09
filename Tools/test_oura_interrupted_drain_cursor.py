"""Source contract for #2443: retain a mid-drain cursor before its anchor disappears.

Moved from the Android JVM suite because this reads BOTH platforms. The unfiltered
core Tools suite runs it when either implementation changes (the #2587 CI lesson).
This checks wiring, not CoreBluetooth/GATT behavior or hardware interoperability.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCES = {
    "Swift": ROOT / "Strand/BLE/OuraLiveSource.swift",
    "Kotlin": ROOT / "android/app/src/main/java/com/noop/ble/OuraLiveSource.kt",
}


def call_sites(source, name):
    """Exclude declarations and comment mentions, as the original JVM guard did."""
    offsets = []
    for match in re.finditer(r"\b" + re.escape(name) + r"\(\)", source):
        prefix = source[source.rfind("\n", 0, match.start()) + 1:match.start()].strip()
        if not prefix.startswith(("private fun", "private func", "*", "//")):
            offsets.append(match.start())
    return offsets


def assert_cursor_wiring(source, label):
    commits = call_sites(source, "commitInterruptedDrainCursor")
    assert len(commits) == 2, f"{label}: expected a cursor commit at BOTH teardowns"
    flushes = call_sites(source, "dropUnanchoredHypnogramBursts")
    for commit in commits:
        before = [offset for offset in flushes if offset < commit]
        assert before and commit - before[-1] < 400, (
            f"{label}: cursor commit must follow the hypnogram flush"
        )
    if label == "Swift":
        stops = [m.start() for m in re.finditer(r"driver\?\.stop\(\)", source)]
        for commit in commits:
            after = [offset for offset in stops if offset > commit]
            assert after and after[0] - commit < 200, (
                "Swift: cursor commit must precede driver teardown"
            )
    declaration = "private func" if label == "Swift" else "private fun"
    start = source.index(f"{declaration} commitInterruptedDrainCursor()")
    end = source.index(f"{declaration} commitResumeCursor", start)
    helper = source[start:end]
    required = (
        ("driver.phase == .fetchingHistory", "drain.maxStoredRingTime > 0",
         "!drain.sawPreResumeData", "commitResumeCursor(drainCompleted: false)")
        if label == "Swift" else
        ("OuraDriverPhase.FetchingHistory", "drain.maxStoredRingTime <= 0",
         "if (drain.sawPreResumeData) return", "commitResumeCursor(drainCompleted = false)")
    )
    for marker in required:
        assert marker in helper, f"{label}: interrupted-drain helper lost gate/rule: {marker}"


class OuraInterruptedDrainCursorTests(unittest.TestCase):
    def test_both_platforms_preserve_interrupted_drain_cursor_wiring(self):
        for label, path in SOURCES.items():
            with self.subTest(platform=label):
                assert_cursor_wiring(path.read_text(encoding="utf-8"), label)

    def test_removing_either_teardown_commit_fails(self):
        for label, path in SOURCES.items():
            source = path.read_text(encoding="utf-8")
            for offset in call_sites(source, "commitInterruptedDrainCursor"):
                with self.subTest(platform=label, offset=offset):
                    changed = source[:offset] + source[offset:].replace(
                        "commitInterruptedDrainCursor()", "", 1)
                    with self.assertRaisesRegex(AssertionError, "BOTH teardowns"):
                        assert_cursor_wiring(changed, label)

    def test_committing_before_the_flush_fails(self):
        for label, path in SOURCES.items():
            source = path.read_text(encoding="utf-8")
            changed = source.replace("dropUnanchoredHypnogramBursts()", "missingFlush()")
            with self.subTest(platform=label):
                with self.assertRaisesRegex(AssertionError, "hypnogram flush"):
                    assert_cursor_wiring(changed, label)

    def test_committing_after_driver_teardown_fails(self):
        source = SOURCES["Swift"].read_text(encoding="utf-8")
        changed = re.sub(
            r"(commitInterruptedDrainCursor\(\)[^\n]*\n)(\s*driver\?\.stop\(\)\n)",
            r"\2\1", source)
        self.assertNotEqual(source, changed)
        with self.assertRaisesRegex(AssertionError, "driver teardown"):
            assert_cursor_wiring(changed, "Swift")

    def test_helper_requires_history_phase_and_banked_progress(self):
        for label, path in SOURCES.items():
            source = path.read_text(encoding="utf-8")
            gates = ("driver.phase == .fetchingHistory", "drain.maxStoredRingTime > 0") if label == "Swift" else (
                "OuraDriverPhase.FetchingHistory", "drain.maxStoredRingTime <= 0")
            for gate in gates:
                with self.subTest(platform=label, gate=gate):
                    with self.assertRaisesRegex(AssertionError, "lost gate/rule"):
                        assert_cursor_wiring(source.replace(gate, "missingGate"), label)

    def test_interrupted_drain_cannot_make_the_reboot_judgement(self):
        for label, path in SOURCES.items():
            source = path.read_text(encoding="utf-8")
            gate = "!drain.sawPreResumeData" if label == "Swift" else "if (drain.sawPreResumeData) return"
            with self.subTest(platform=label):
                with self.assertRaisesRegex(AssertionError, "lost gate/rule"):
                    assert_cursor_wiring(source.replace(gate, "missingRebootGate"), label)


if __name__ == "__main__":
    unittest.main()
