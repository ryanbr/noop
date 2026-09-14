"""Source contracts for cross-platform legacy WHOOP 5 score preservation."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SWIFT_ENGINE = ROOT / "Strand/Data/IntelligenceEngine.swift"
ANDROID_PERSISTENCE = (
    ROOT
    / "android/app/src/main/java/com/noop/analytics/IntelligencePersistence.kt"
)


class LegacyScorePreservationContractTests(unittest.TestCase):
    def test_swift_protects_only_the_persisted_and_displayed_copy(self) -> None:
        source = SWIFT_ENGINE.read_text()
        protection_start = source.index("// Apply the exact snapshot only after")
        persistence_end = source.index("markPostLoopPhase(\"persist\")", protection_start)
        persistence = source[protection_start:persistence_end]

        self.assertIn("var persistedDailies = dailies", persistence)
        self.assertIn("for index in persistedDailies.indices", persistence)
        self.assertIn("let fresh = persistedDailies[index]", persistence)
        self.assertIn("persistedDailies[index] = fresh.with(avgHrv: snapshot.avgHrv", persistence)
        self.assertIn("recovery: snapshot.recovery", persistence)
        self.assertIn("respRateBpm: snapshot.respRateBpm", persistence)
        self.assertIn("avgSdnn: snapshot.avgSdnn", persistence)
        self.assertIn("for daily in persistedDailies", persistence)
        self.assertIn("dailyMetrics: persistedDailies", persistence)
        self.assertNotIn("dailies[index] = fresh.with(avgHrv:", persistence)

        derivations = source[persistence_end:]
        self.assertIn("let fa7 = dailies.sorted", derivations)
        self.assertIn("for d in dailies { faGateByDay[d.day] = d }", derivations)
        self.assertIn("let vHRVs = fa7.compactMap { $0.avgHrv }", derivations)
        self.assertNotIn("persistedDailies", derivations)

    def test_android_also_protects_a_separate_persistence_copy(self) -> None:
        source = ANDROID_PERSISTENCE.read_text()
        preparation_start = source.index("suspend fun prepareComputedWindow")
        preparation_end = source.index("fun scoreProvenance", preparation_start)
        preparation = source[preparation_start:preparation_end]

        self.assertIn("val mutableDailies = dailies.toMutableList()", preparation)
        self.assertIn(
            "repo, computedId, from, to, mutableDailies, ownerByDay,",
            preparation,
        )
        self.assertIn("dailies = mutableDailies", preparation)
        self.assertIn("respRateBpm = existing.respRateBpm", source)
        self.assertIn("avgSdnn = existing.avgSdnn", source)


if __name__ == "__main__":
    unittest.main()
