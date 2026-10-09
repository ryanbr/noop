"""Execute both production gravity witnesses and guard their bounded query improvement."""

import re
import sqlite3
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
COMBINED = (
    "SELECT COUNT(*) AS c, COALESCE(MAX(ts), 0) AS m FROM gravitySample "
    "WHERE deviceId = :deviceId AND ts >= :from AND ts <= :to"
)


def production_queries():
    swift = (ROOT / "Packages/WhoopStore/Sources/WhoopStore/Reads.swift").read_text()
    method = swift.split("public func gravityFingerprint(", 1)[1]
    sql = method.split('sql: """', 1)[1].split('"""', 1)[0]
    # The Swift twin binds the same three values twice, once for each subquery. Actual binding is also
    # exercised by GravityWitnessTests through GRDB; this adapter only runs the SQL on Python's SQLite.
    names = iter([":deviceId", ":from", ":to", ":deviceId", ":from", ":to"])
    swift_sql = re.sub(r"\?", lambda _: next(names), sql)
    kotlin = (ROOT / "android/app/src/main/java/com/noop/data/WhoopDao.kt").read_text()
    query = kotlin.split("suspend fun gravityWitnessInWindow(", 1)[0].rsplit("@Query(", 1)[1]
    kotlin_sql = "".join(re.findall(r'"([^"\n]*)"', query))
    return {"Swift": swift_sql, "Kotlin": kotlin_sql}


class GravityWitnessQueryTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        # Same covering primary-key index as Room/GRDB, with real vectors kept outside that index.
        self.db.execute(
            "CREATE TABLE gravitySample(deviceId TEXT NOT NULL, ts INTEGER NOT NULL, "
            "x REAL NOT NULL, y REAL NOT NULL, z REAL NOT NULL, PRIMARY KEY(deviceId, ts))"
        )
        self.queries = production_queries()

    def tearDown(self):
        self.db.close()

    def insert(self, device, times):
        self.db.executemany(
            "INSERT OR IGNORE INTO gravitySample VALUES(?,?,?,?,?)",
            ((device, ts, 1.0, 2.0, 3.0) for ts in times),
        )

    def assert_witness(self, expected, device="dev", start=0, end=1000):
        params = {"deviceId": device, "from": start, "to": end}
        for platform, query in self.queries.items():
            with self.subTest(platform=platform, device=device, start=start, end=end):
                self.assertEqual(self.db.execute(query, params).fetchone(), expected)

    def test_bounds_empty_and_other_device(self):
        self.insert("dev", [-20, -10, 0, 100, 200, 1000, 1001])
        self.insert("other", [150, 5000])
        for expected, start, end in [
            ((4, 1000), 0, 1000), ((2, 200), 100, 200), ((1, 100), 100, 100),
            ((0, 0), 201, 999), ((0, 0), 200, 100), ((2, -10), -20, -1),
        ]:
            self.assert_witness(expected, start=start, end=end)
        self.assert_witness((0, 0), device="absent")
        self.assert_witness((1, 150), device="other")

    def test_append_backfill_duplicates_and_deletes(self):
        self.assert_witness((0, 0))
        self.insert("dev", [200])
        self.assert_witness((1, 200))
        self.insert("dev", [300])
        self.assert_witness((2, 300))
        self.insert("dev", [100, 200])
        self.assert_witness((3, 300))
        self.db.execute("DELETE FROM gravitySample WHERE ts = 100")
        self.assert_witness((2, 300))
        self.db.execute("DELETE FROM gravitySample WHERE ts = 300")
        self.assert_witness((1, 200))
        self.db.execute("DELETE FROM gravitySample")
        self.assert_witness((0, 0))
        self.insert("dev", [100])
        self.assert_witness((1, 100))

    def test_agrees_with_combined_witness_across_windows(self):
        self.insert("dev", range(-120, 1000, 7))
        self.insert("other", range(-100, 2000, 11))
        for device in ["dev", "other", "absent"]:
            for start in [-200, -20, 0, 77, 500, 1000]:
                for end in [-100, 0, 77, 300, 999, 2000]:
                    params = {"deviceId": device, "from": start, "to": end}
                    expected = self.db.execute(COMBINED, params).fetchone()
                    self.assert_witness(expected, device=device, start=start, end=end)

    def test_max_seek_reduces_vm_work_without_wall_clock_assertions(self):
        self.insert("dev", range(10000))
        params = {"deviceId": "dev", "from": 0, "to": 9999}

        def work(query):
            ticks = 0

            def progress():
                nonlocal ticks
                ticks += 1
                return 0

            self.db.set_progress_handler(progress, 100)
            try:
                self.assertEqual(self.db.execute(query, params).fetchone(), (10000, 9999))
            finally:
                self.db.set_progress_handler(None, 0)
            return ticks

        combined_work = work(COMBINED)
        for platform, query in self.queries.items():
            with self.subTest(platform=platform):
                # Broad margin around the observed ~half VM work. COUNT still walks all rows; this
                # guards only removing the per-row MAX aggregate, not constant-time invalidation.
                self.assertLess(work(query), combined_work * 0.75)


if __name__ == "__main__":
    unittest.main()
