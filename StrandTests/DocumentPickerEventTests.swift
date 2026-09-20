import XCTest
@testable import Strand

/// What the backup folder picker is allowed to claim (#2356).
///
/// UIKit calls `documentPickerWasCancelled` both when someone taps Cancel and when someone picks a
/// folder, taps Open, and iOS declines to grant it. Nothing in the API separates them. Reporting
/// "cancelled" asserts an intent that was never observed, and it cost a real investigation: a reporter
/// hit the second case while the log claimed the first, so the previous work went after an Open button
/// that stays disabled, which was never the problem.
///
/// Source-asserted because the delegate needs UIKit and a presented sheet, the same reason
/// `PiiRedactionTests` reads source. These pin the wording contract, not the picker's behaviour.
final class DocumentPickerEventTests: XCTestCase {

    /// The no-URL outcome must describe what happened, not why someone did it.
    func testTheNoUrlOutcomeDoesNotClaimTheUserCancelled() throws {
        let code = Self.codeLines(of: try Self.pickerSource())
        XCTAssertTrue(code.contains { $0.contains("\"closed without a folder\"") },
                      "the no-URL event must say the sheet closed with nothing, which is what we observe")
        XCTAssertFalse(code.contains { $0.contains("recordEvent(\"cancelled\"") },
                       "\"cancelled\" asserts an intent UIKit never reports")
    }

    /// The two facts that let a reader separate a Cancel tap from a refused grant.
    ///
    /// A tap on Cancel closes the sheet in a second or two; navigating into iCloud Drive and choosing a
    /// folder takes far longer. Without the duration the log cannot distinguish them at all.
    func testTheOutcomeCarriesHowLongThePickerWasOpen() throws {
        let src = try Self.pickerSource()
        XCTAssertTrue(src.contains("private let presentedAt = Date()"),
                      "the coordinator must note when the sheet went up")
        XCTAssertTrue(src.contains("openSeconds: Date().timeIntervalSince(presentedAt)"),
                      "both delegate outcomes must report how long the picker was open")
    }

    /// The companions must be written even when absent, or they outlive the event they describe.
    ///
    /// Writing them only when present would leave the duration and start folder from an earlier pick
    /// sitting beside a newer event, and the export would read as though the two belonged together.
    func testTheCompanionFieldsCannotGoStaleAgainstTheEvent() throws {
        let code = Self.codeLines(of: try Self.pickerSource())
        XCTAssertTrue(code.contains { $0.contains("d.set(openSeconds ?? 0, forKey:") },
                      "the duration must be written unconditionally, including the nil case")
        XCTAssertTrue(code.contains { $0.contains("d.set(startedIn ?? \"\", forKey:") },
                      "the start category must be written unconditionally too")
        XCTAssertFalse(code.contains { $0.contains("if let openSeconds {") },
                       "a conditional write leaves the previous pick's duration beside a newer event")
    }

    /// The export must never carry the NAME of a folder someone chose.
    ///
    /// The debug export is what people attach to public issues and it is not redacted. A folder name can
    /// carry a person's name as easily as a strap can (#2337). The picked folder's name has always been
    /// stored and never printed; the starting directory must follow the same rule, so what is recorded is
    /// which KIND of folder it opened on, never the folder itself.
    func testTheStartingFolderIsACategoryNotAName() throws {
        let code = Self.codeLines(of: try Self.pickerSource())
        XCTAssertTrue(code.contains { $0.contains("startedIn: BackupPickerStart.category(") },
                      "the delegate must record a category, not the directory URL")
        XCTAssertFalse(code.contains { $0.contains("startedAt: controller.directoryURL") },
                       "a picked directory URL must not reach the export")
        let export = try Self.exportSource()
        XCTAssertFalse(Self.codeLines(of: export).contains { $0.contains("backupPicker.lastName") },
                       "the picked folder's own name must stay off the export, as it always has")
    }

    private static func exportSource(file: StaticString = #filePath) throws -> String {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<4 {
            let candidate = dir.appendingPathComponent("Strand/System/DebugDataDiagnostics.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw SourceNotReachable(path: "\(file)")
    }

    // MARK: - The category itself, run rather than matched

    /// No directory set means the picker opened wherever it liked.
    func testNoDirectoryIsThePickerDefault() {
        XCTAssertEqual(BackupPickerStart.category(nil), "the picker default")
    }

    /// Our own Documents is the fallback #1000a passes when there is no last-used folder.
    func testOurOwnDocumentsIsNamedAsSuch() {
        let ours = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let resolved = try? XCTUnwrap(ours)
        XCTAssertEqual(BackupPickerStart.category(resolved), "NOOP's own folder")
    }

    /// Anything else is the user's last-used folder, and is described WITHOUT naming it.
    ///
    /// The assertion that matters is the second one: whatever the folder is called, its name must not
    /// appear in the string that reaches the export.
    func testAnyOtherDirectoryIsDescribedWithoutItsName() {
        let personal = URL(fileURLWithPath: "/tmp/Ryan's Backups")
        let category = BackupPickerStart.category(personal)
        XCTAssertEqual(category, "a folder you chose")
        XCTAssertFalse(category.contains("Ryan"), "a folder name must never reach the debug export")
        XCTAssertFalse(category.contains("Backups"), "nor any part of it")
    }

    /// A trailing slash is the same folder, so it must not read as somebody else's.
    func testTrailingSlashesDoNotChangeTheAnswer() {
        let ours = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let ours else { return XCTFail("no Documents directory") }
        let withSlash = URL(fileURLWithPath: ours.path + "/")
        XCTAssertEqual(BackupPickerStart.category(withSlash), "NOOP's own folder")
    }

    // MARK: - Source access

    /// Source lines with comment-only lines dropped, so prose about a rule cannot trip the rule. That
    /// exact shape failed `BodyClockDialLayoutTests` on CI, where a comment naming the banned call
    /// tripped the assertion that the call was absent.
    private static func codeLines(of src: String) -> [String] {
        src.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    private struct SourceNotReachable: Error, CustomStringConvertible {
        let path: String
        var description: String { "DocumentPicker.swift not reachable from \(path)" }
    }

    private static func pickerSource(file: StaticString = #filePath) throws -> String {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<4 {
            let candidate = dir.appendingPathComponent("Strand/System/DocumentPicker.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw SourceNotReachable(path: "\(file)")
    }
}
