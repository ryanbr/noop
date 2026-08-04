import XCTest
import GRDB
@testable import WhoopStore

/// SHARED Room<->GRDB SCHEMA ORACLE — the Swift half of a cross-platform schema drift guard (#775).
///
/// `Resources/schema_oracle.json` pins, for every table, the columns **in order** with their SQLite
/// type affinity / NOT NULL / DEFAULT, the primary-key composition, and the explicit indices. The
/// IDENTICAL file is committed at `android/app/src/test/resources/schema_oracle.json`, and
/// `SchemaOracleTest.kt` asserts Room's generated schema against it. This half runs the real GRDB
/// migrator into an in-memory database and asserts `PRAGMA table_info` / `index_list` against the
/// same fixture.
///
/// Room and GRDB are independent reimplementations of one schema, so a migration added on one side
/// can diverge until someone notices by hand — which already happened once (rrInterval's key was
/// widened on Room v18 and only later on GRDB `v24-rr-seq`). Comparing both **resulting** schemas to
/// one shared file is what turns CLAUDE.md's parity contract from a comment into a check.
///
/// The oracle records the **iOS/GRDB shape as canonical** (macOS is the reference implementation).
/// Every way Android differs today is spelled out as an `android` / `iosAbsent` / `androidColumnOrder`
/// override naming a key in `divergenceReasons`, so a divergence is either fixed or written down —
/// never silently tolerated. An override that stops being true fails the Kotlin half, so the ledger
/// can only shrink deliberately.
///
/// Follows the `decoder_oracle.json` idiom (#869) rather than adding a third mechanism.
final class SchemaOracleTests: XCTestCase {

    // MARK: - Fixture

    struct Oracle: Decodable {
        let roomVersion: Int
        let grdbMigrations: [String]
        let divergenceReasons: [String: String]
        let tables: [String: OracleTable]
    }
    struct OracleTable: Decodable {
        let platform: String                 // "both" | "ios_only" | "android_only"
        let columns: [OracleColumn]
        let primaryKey: [String]
        let indices: [OracleIndex]
        let androidColumnOrder: [String]?
        let androidColumnOrderDivergence: String?
    }
    struct OracleColumn: Decodable {
        let name: String
        let affinity: String
        let notNull: Bool
        let `default`: String?
        let iosAbsent: Bool?
        let androidAbsent: Bool?
        let android: AndroidOverride?
        let divergence: DivergenceKeys?
    }
    struct OracleIndex: Decodable {
        let name: String
        let unique: Bool
        let columns: [String]
    }
    struct AndroidOverride: Decodable {
        let affinity: String?
        let notNull: Bool?
        let `default`: String?
        /// `"default": null` and an absent `default` mean different things: the first says Android has NO
        /// SQL default where iOS has one, the second says the default is not overridden at all.
        let overridesDefault: Bool
        private enum CodingKeys: String, CodingKey { case affinity, notNull, `default` }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            affinity = try c.decodeIfPresent(String.self, forKey: .affinity)
            notNull = try c.decodeIfPresent(Bool.self, forKey: .notNull)
            `default` = try c.decodeIfPresent(String.self, forKey: .default)
            overridesDefault = c.contains(.default)
        }
    }
    /// One key, or several when a column diverges in more than one way.
    struct DivergenceKeys: Decodable {
        let keys: [String]
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let one = try? c.decode(String.self) { keys = [one]; return }
            keys = try c.decode([String].self)
        }
    }

    private func loadOracle() throws -> Oracle {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "schema_oracle", withExtension: "json"),
                                "missing schema_oracle.json test resource")
        return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
    }

    // MARK: - Live GRDB schema

    /// SQLite type affinity from a declared column type (datatype3 §3.1). GRDB writes DOUBLE where Room
    /// writes REAL — both REAL affinity, so the rule collapses a spelling difference that is not drift,
    /// while keeping BOOLEAN (NUMERIC) distinct from INTEGER, which genuinely is. The Kotlin half runs
    /// the identical function over Room's exported affinity.
    static func sqliteAffinity(of declaredType: String) -> String {
        let t = declaredType.uppercased()
        if t.contains("INT") { return "INTEGER" }
        if t.contains("CHAR") || t.contains("CLOB") || t.contains("TEXT") { return "TEXT" }
        if t.contains("BLOB") || t.isEmpty { return "BLOB" }
        if t.contains("REAL") || t.contains("FLOA") || t.contains("DOUB") { return "REAL" }
        return "NUMERIC"
    }

    /// The columns the oracle expects THIS platform to have: canonical order, minus Android-only ones.
    private func iosExpectedColumns(_ table: OracleTable) -> [LiveColumn] {
        table.columns.filter { $0.iosAbsent != true }
            .map { LiveColumn(name: $0.name, affinity: $0.affinity, notNull: $0.notNull, default: $0.default) }
    }

    // MARK: - Tests

    /// Every GRDB table matches the oracle: column names **in order**, affinity, NOT NULL, DEFAULT,
    /// primary-key composition, and explicit indices.
    ///
    /// Reports EVERY mismatch rather than stopping at the first: a schema that has drifted has usually
    /// drifted in more than one place, and a guardrail that surfaces one column per run turns a single
    /// review into several.
    func testGrdbSchemaMatchesOracle() async throws {
        let oracle = try loadOracle()
        let live = try await WhoopStore.inMemory().liveSchemaForTest()
        var problems: [String] = []

        for (name, table) in oracle.tables.sorted(by: { $0.key < $1.key }) {
            guard table.platform != "android_only" else {
                if live[name] != nil {
                    problems.append("\(name): declared android_only in schema_oracle.json but GRDB now "
                                    + "creates it — it gained a twin: move it to platform \"both\" and pin "
                                    + "its columns.")
                }
                continue
            }
            guard let actual = live[name] else {
                problems.append("\(name): pinned by schema_oracle.json but the GRDB migrator never creates it")
                continue
            }
            let expected = iosExpectedColumns(table)
            if actual.columns.map(\.name) != expected.map(\.name) {
                problems.append("\(name): GRDB column ORDER/SET differs from schema_oracle.json\n"
                                + "      oracle: \(expected.map(\.name))\n"
                                + "      grdb:   \(actual.columns.map(\.name))")
            }
            for (want, got) in zip(expected, actual.columns) where want.name == got.name {
                if got.affinity != want.affinity {
                    problems.append("\(name).\(want.name): type affinity — oracle \(want.affinity), grdb \(got.affinity)")
                }
                if got.notNull != want.notNull {
                    problems.append("\(name).\(want.name): NOT NULL — oracle \(want.notNull), grdb \(got.notNull)")
                }
                if got.default != want.default {
                    problems.append("\(name).\(want.name): DEFAULT — oracle \(want.default ?? "none"), "
                                    + "grdb \(got.default ?? "none")")
                }
            }
            if actual.primaryKey != table.primaryKey {
                problems.append("\(name): PRIMARY KEY — oracle \(table.primaryKey), grdb \(actual.primaryKey)")
            }
            if actual.indices.map({ $0.name }) != table.indices.map({ $0.name }) {
                problems.append("\(name): index names — oracle \(table.indices.map { $0.name }), "
                                + "grdb \(actual.indices.map { $0.name })")
            }
            for want in table.indices {
                guard let got = actual.indices.first(where: { $0.name == want.name }) else { continue }
                if got.unique != want.unique {
                    problems.append("\(name).\(want.name): UNIQUE — oracle \(want.unique), grdb \(got.unique)")
                }
                if got.columns != want.columns {
                    problems.append("\(name).\(want.name): indexed columns — oracle \(want.columns), grdb \(got.columns)")
                }
            }
        }
        XCTAssertTrue(problems.isEmpty,
                      "GRDB schema drifted from schema_oracle.json (\(problems.count)):\n  - "
                      + problems.joined(separator: "\n  - "))
    }

    /// The oracle cannot quietly stop covering a table: every table the migrator creates must be pinned.
    /// This is what fails when a new migration adds a table and the fixture is not updated.
    func testOracleCoversEveryGrdbTable() async throws {
        let oracle = try loadOracle()
        let live = try await WhoopStore.inMemory().liveSchemaForTest()
        let unpinned = Set(live.keys).subtracting(oracle.tables.keys).sorted()
        XCTAssertTrue(unpinned.isEmpty,
                      "GRDB tables missing from schema_oracle.json: \(unpinned). A new table needs a Room "
                      + "twin (or an explicit ios_only entry) before it can land.")
    }

    /// The registered migration identifiers are pinned, so a new GRDB migration cannot land without the
    /// author opening this fixture and looking at the Android side.
    func testGrdbMigrationIdentifiersMatchOracle() throws {
        let oracle = try loadOracle()
        XCTAssertEqual(WhoopStore.makeMigrator().migrations, oracle.grdbMigrations,
                       "registered GRDB migrations differ from schema_oracle.json")
    }

    /// GRDB keys migrations by NAME and applies them in registration order; Room keys by integer
    /// version. Two migrations that both claim `vN` (PRs #369 and #475 each proposed a `v31`) are
    /// DISTINCT identifiers to GRDB, so both run happily and the vN <-> Room-version mapping silently
    /// becomes ambiguous. Worse, an exactly-duplicated identifier makes GRDB skip the second body
    /// entirely, because the first already recorded that name in `grdb_migrations`.
    ///
    /// So: identifiers unique, and their `vN` prefixes exactly 1...N with no gaps and no repeats.
    func testGrdbMigrationIdentifiersAreUniqueAndSequential() throws {
        let ids = WhoopStore.makeMigrator().migrations
        XCTAssertEqual(Set(ids).count, ids.count,
                       "duplicate GRDB migration identifier — GRDB would silently SKIP the second body")

        var numbers: [Int] = []
        for id in ids {
            let digits = id.dropFirst().prefix { $0.isNumber }
            guard id.hasPrefix("v"), let n = Int(digits) else {
                return XCTFail("migration identifier '\(id)' is not of the form v<N>[-slug]")
            }
            numbers.append(n)
        }
        for (offset, n) in numbers.enumerated() where n != offset + 1 {
            return XCTFail("GRDB migration '\(ids[offset])' claims v\(n) but is #\(offset + 1) in "
                           + "registration order — two migrations claiming the same vN, or a gap, makes the "
                           + "GRDB-name <-> Room-version mapping ambiguous. Renumber before merging.")
        }
    }

    /// No stale entry in the divergence ledger: every declared reason must be referenced by a column or
    /// table. A divergence that gets FIXED must be deleted from the fixture, not left to rot.
    func testEveryDivergenceReasonIsReferenced() throws {
        let oracle = try loadOracle()
        var used = Set<String>()
        for table in oracle.tables.values {
            for column in table.columns { column.divergence?.keys.forEach { used.insert($0) } }
            if let key = table.androidColumnOrderDivergence { used.insert(key) }
        }
        let unused = Set(oracle.divergenceReasons.keys).subtracting(used).sorted()
        XCTAssertTrue(unused.isEmpty, "divergenceReasons entries nothing references: \(unused)")
        let undeclared = used.subtracting(oracle.divergenceReasons.keys).sorted()
        XCTAssertTrue(undeclared.isEmpty, "divergences with no reason written down: \(undeclared)")
    }

    /// Fixture integrity: a declared Android override must actually override something, and a table with
    /// an `androidColumnOrder` must list exactly the columns Android has. A no-op override would look
    /// like a tolerated divergence while tolerating nothing, hiding a real one behind it.
    func testDivergenceOverridesAreWellFormed() throws {
        let oracle = try loadOracle()
        for (name, table) in oracle.tables {
            for column in table.columns {
                if let android = column.android {
                    XCTAssertNotNil(column.divergence,
                                    "\(name).\(column.name): android override with no reason key")
                    var differs = false
                    if let affinity = android.affinity, affinity != column.affinity { differs = true }
                    if let notNull = android.notNull, notNull != column.notNull { differs = true }
                    if android.overridesDefault, android.default != column.default { differs = true }
                    XCTAssertTrue(differs, "\(name).\(column.name): android override changes nothing")
                }
                if column.iosAbsent == true || column.androidAbsent == true {
                    XCTAssertNotNil(column.divergence,
                                    "\(name).\(column.name): platform-absent column with no reason key")
                }
                XCTAssertFalse(column.iosAbsent == true && column.androidAbsent == true,
                               "\(name).\(column.name): absent on both platforms — delete it")
            }
            if let order = table.androidColumnOrder {
                let allNames = table.columns.map { $0.name }   // canonical order incl. Android-only
                XCTAssertEqual(order.sorted(), allNames.sorted(),
                               "\(name): androidColumnOrder is not a permutation of the table's columns")
                XCTAssertNotEqual(order, allNames,
                                  "\(name): androidColumnOrder equals the canonical order — delete it")
                XCTAssertNotNil(table.androidColumnOrderDivergence,
                                "\(name): androidColumnOrder with no reason key")
            }
        }
    }

    /// The Swift and Android copies of the oracle MUST be byte-identical, so neither platform can edit
    /// its fixture without the other. Skips gracefully if the Android tree isn't present.
    func testOracleCopiesAreIdentical() throws {
        let swiftURL = try XCTUnwrap(Bundle.module.url(forResource: "schema_oracle", withExtension: "json"))
        let swiftData = try Data(contentsOf: swiftURL)

        // .../Packages/WhoopStore/Tests/WhoopStoreTests/SchemaOracleTests.swift -> repo root
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // WhoopStoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // WhoopStore
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
        let androidURL = repoRoot.appendingPathComponent("android/app/src/test/resources/schema_oracle.json")
        guard FileManager.default.fileExists(atPath: androidURL.path) else {
            throw XCTSkip("android oracle copy not present at \(androidURL.path)")
        }
        XCTAssertEqual(swiftData, try Data(contentsOf: androidURL),
                       "schema_oracle.json copies differ — keep the Swift and Android copies in lockstep")
    }
}

/// One column as `PRAGMA table_info` reports it, normalised to SQLite's type **affinity** so the
/// comparison is about how the value is stored, not how the DDL happened to spell the type.
struct LiveColumn: Equatable {
    let name: String, affinity: String, notNull: Bool, `default`: String?
}
struct LiveIndex: Equatable {
    let name: String, unique: Bool, columns: [String]
}
struct LiveTable {
    let columns: [LiveColumn], primaryKey: [String], indices: [LiveIndex]
}

extension WhoopStore {
    /// The real, migrated schema straight out of `PRAGMA table_info` / `index_list`. On the actor so it
    /// can use the internal synchronous GRDB helper; test-only, hence no shipping-code change.
    func liveSchemaForTest() throws -> [String: LiveTable] {
        try syncRead { db in
            let names = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            var out: [String: LiveTable] = [:]
            for table in names where !table.hasPrefix("sqlite_") && !table.hasPrefix("grdb_") {
                let columns = try db.columns(in: table).map {
                    LiveColumn(name: $0.name,
                               affinity: SchemaOracleTests.sqliteAffinity(of: $0.type),
                               notNull: $0.isNotNull,
                               default: $0.defaultValueSQL)
                }
                // SQLite's implicit PK/UNIQUE indexes are an artefact of the PRIMARY KEY declaration
                // (compared directly by the oracle) and Room's export never lists them.
                let indices = try db.indexes(on: table)
                    .filter { !$0.name.hasPrefix("sqlite_autoindex_") }
                    .map { LiveIndex(name: $0.name, unique: $0.isUnique, columns: $0.columns) }
                    .sorted { $0.name < $1.name }
                out[table] = LiveTable(columns: columns,
                                       primaryKey: try db.primaryKey(table).columns,
                                       indices: indices)
            }
            return out
        }
    }
}
