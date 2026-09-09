import Foundation
import WhoopStore
import ZIPFoundation

// Build a Lift Log PROGRAM from a spreadsheet filled in on a computer.
//
// WHY THIS EXISTS. A program is a name plus an ordered list of exercise lines, and every line carries
// an exercise, a muscle classification, sets, reps, a weight, a rest period and a technique note.
// Typing all of that on a phone, for a dozen exercises, is the single most tedious thing in the
// feature — and it is exactly the kind of work a spreadsheet on a real keyboard is good at.
//
// This reads the filled-in sheet and produces programs. It never writes: the caller decides what to
// do with the result, which keeps this parser pure and testable with no store and no app.
//
// TWO FORMATS, ONE PARSER. `.xlsx` is what the shipped template is, because a spreadsheet can lock
// its own structure and offer the muscle vocabulary as a dropdown — the user cannot mistype a muscle
// name that has to match a closed token set. CSV is accepted too, because every spreadsheet program
// on every platform can save it, and because a user who rebuilds the sheet by hand should not be
// blocked. Detection is by ZIP magic bytes, the same way `DataBackup` tells a zipped backup from a
// bare SQLite file.

/// One exercise line read from the sheet — the TARGETS, mirroring `liftProgramItem`.
public struct ImportedProgramLine: Sendable, Equatable {
    public var exercise: String
    public var primaryMuscle: LiftMuscle?
    public var secondaryMuscles: [LiftMuscle]
    public var targetSets: Int?
    public var targetReps: Int?
    public var targetWeightKg: Double?
    public var restSec: Int?
    public var note: String?

    public init(exercise: String, primaryMuscle: LiftMuscle?, secondaryMuscles: [LiftMuscle],
                targetSets: Int?, targetReps: Int?, targetWeightKg: Double?,
                restSec: Int?, note: String?) {
        self.exercise = exercise
        self.primaryMuscle = primaryMuscle
        self.secondaryMuscles = secondaryMuscles
        self.targetSets = targetSets
        self.targetReps = targetReps
        self.targetWeightKg = targetWeightKg
        self.restSec = restSec
        self.note = note
    }
}

/// One program: a name, an optional note, and its lines IN SHEET ORDER.
public struct ImportedProgram: Sendable, Equatable {
    public var name: String
    public var note: String?
    public var lines: [ImportedProgramLine]

    public init(name: String, note: String?, lines: [ImportedProgramLine]) {
        self.name = name
        self.note = note
        self.lines = lines
    }
}

/// What a sheet produced, plus everything that was wrong with it.
///
/// Warnings are per-row and NON-fatal by design. A sheet with one misspelled muscle should import
/// eleven good lines and tell the user about the twelfth, not refuse the file — the alternative is a
/// user fixing one typo at a time through twelve round trips.
public struct LiftProgramImportResult: Sendable, Equatable {
    public var programs: [ImportedProgram]
    public var warnings: [String]

    public init(programs: [ImportedProgram], warnings: [String]) {
        self.programs = programs
        self.warnings = warnings
    }
}

public enum LiftProgramSheetImporter {

    public enum ImportError: Error, Equatable {
        /// Not a spreadsheet this can read at all.
        case unreadable
        /// Readable, but without the columns that make it a program sheet.
        case missingColumns([String])
        /// Read fine, but there was nothing in it.
        case empty
        /// Too big to be a program sheet — see `maxFileBytes`.
        case tooLarge
    }

    // MARK: - Bounds
    //
    // A program is a few dozen rows. Everything below is far above any real sheet and far below
    // anything that could hurt: this feature is a convenience, and it must never be the reason the
    // app is slow, runs out of memory, or writes a database nobody wants.

    /// A filled template is ~9 KB; a hand-built sheet with a year of programs is still well under a
    /// megabyte. 8 MB is generous enough that no honest file is refused, and small enough that
    /// reading it whole into memory on a phone is nothing.
    public static let maxFileBytes = 8 * 1024 * 1024

    /// Rows considered from a sheet. A spreadsheet can carry a million empty rows, and some writers
    /// emit them; parsing them all is wasted work and the result would be unusable anyway.
    static let maxRows = 5_000

    /// Exercise lines kept per program. A program with more lines than this is not a program.
    static let maxLinesPerProgram = 200

    /// Programs created from one file.
    static let maxPrograms = 50

    /// Warnings reported. A pathological sheet could otherwise produce thousands, which helps nobody
    /// and makes the preview unscrollable; the count is still reported honestly (see `warnings`).
    static let maxWarnings = 50

    /// Column keys, after `HeaderNorm.normalize`. Several spellings map to the same field so a user
    /// who retypes the header — or translates it — is not punished for it.
    private static let exerciseKeys = ["exercise", "movement", "lift"]
    private static let programKeys = ["program", "programme", "workout", "routine", "day"]
    private static let programNoteKeys = ["program_note", "programme_note", "workout_note", "routine_note"]
    private static let primaryKeys = ["primary_muscle", "primary", "muscle"]
    private static let secondaryKeys = ["secondary_muscles", "secondary_muscle", "secondary"]
    private static let setsKeys = ["sets", "working_sets", "target_sets"]
    private static let repsKeys = ["reps", "rep", "target_reps", "repetitions"]
    private static let weightKeys = ["weight_kg", "weight", "kg", "load", "load_kg"]
    private static let restKeys = ["rest_sec", "rest_seconds", "rest", "rest_s"]
    private static let noteKeys = ["note", "technique_note", "notes", "cue"]

    /// Parse a filled-in template. Detects `.xlsx` by its ZIP magic bytes, else treats it as CSV.
    public static func parse(data: Data) throws -> LiftProgramImportResult {
        // Refuse before doing any work. An .xlsx is a ZIP, so a hostile one can be small on disk and
        // enormous expanded; `XlsxSheet` bounds the expansion separately. This bound is on what the
        // caller handed us.
        guard data.count <= maxFileBytes else { throw ImportError.tooLarge }

        let candidates: [XlsxSheet.Sheet]
        if isZip(data) {
            // Every sheet, in tab order — the workbook may carry instructions, notes or the user's
            // own scratch alongside the program, and only this parser can tell which is which.
            candidates = try XlsxSheet.sheets(from: data)
        } else {
            let table = CSVTable(data: data)
            guard !table.headers.isEmpty else { throw ImportError.unreadable }
            candidates = [XlsxSheet.Sheet(headerKeys: Set(table.normalizedHeaders.filter { !$0.isEmpty }),
                                          rows: table.rows)]
        }

        // An exercise column is the one thing a program sheet cannot do without, so it is also how a
        // program sheet is recognised among several. First match in tab order wins.
        //
        // Matched on HEADERS, not on rows, so the three failures stay distinguishable: a file that is
        // not a program sheet at all, and a correct template nobody has filled in yet, are different
        // mistakes and deserve different advice.
        guard let sheet = candidates.first(where: {
            !$0.headerKeys.isDisjoint(with: exerciseKeys)
        }) else {
            throw ImportError.missingColumns(["exercise"])
        }
        let rows = sheet.rows
        guard !rows.isEmpty else { throw ImportError.empty }

        var programs: [ImportedProgram] = []
        var indexByName: [String: Int] = [:]
        var warnings: [String] = []

        var truncated = false
        for (i, row) in rows.prefix(maxRows).enumerated() {
            // Spreadsheets are full of trailing blank rows; they are not an error.
            let exercise = value(row, exerciseKeys)?.trimmed ?? ""
            if exercise.isEmpty {
                if row.values.contains(where: { !$0.trimmed.isEmpty }), warnings.count < maxWarnings {
                    warnings.append(rowMessage(i, "no exercise name, so the row was skipped"))
                }
                continue
            }

            let programName = value(row, programKeys)?.trimmed.nilIfEmpty ?? "Imported program"

            var primary: LiftMuscle?
            if let raw = value(row, primaryKeys)?.trimmed.nilIfEmpty {
                primary = LiftMuscle(sheetName: raw)
                if primary == nil, warnings.count < maxWarnings {
                    warnings.append(rowMessage(i, "\"\(raw)\" is not a muscle group, so \"\(exercise)\" was left unclassified"))
                }
            }

            var secondary: [LiftMuscle] = []
            if let raw = value(row, secondaryKeys)?.trimmed.nilIfEmpty {
                for part in raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "/" || $0 == "|" }) {
                    let token = String(part).trimmed
                    guard !token.isEmpty else { continue }
                    if let m = LiftMuscle(sheetName: token) {
                        // The store excludes the primary from the secondary list, so do it here too
                        // rather than leaving a row that says "chest, chest".
                        if m != primary, !secondary.contains(m) { secondary.append(m) }
                    } else if warnings.count < maxWarnings {
                        warnings.append(rowMessage(i, "\"\(token)\" is not a muscle group and was ignored"))
                    }
                }
            }

            let line = ImportedProgramLine(
                exercise: exercise,
                primaryMuscle: primary,
                secondaryMuscles: secondary,
                targetSets: intValue(row, setsKeys),
                targetReps: intValue(row, repsKeys),
                targetWeightKg: doubleValue(row, weightKeys),
                restSec: intValue(row, restKeys),
                note: value(row, noteKeys)?.trimmed.nilIfEmpty)

            if let idx = indexByName[programName.lowercased()] {
                guard programs[idx].lines.count < maxLinesPerProgram else { truncated = true; continue }
                programs[idx].lines.append(line)
                if programs[idx].note == nil {
                    programs[idx].note = value(row, programNoteKeys)?.trimmed.nilIfEmpty
                }
            } else {
                guard programs.count < maxPrograms else { truncated = true; continue }
                indexByName[programName.lowercased()] = programs.count
                programs.append(ImportedProgram(
                    name: programName,
                    note: value(row, programNoteKeys)?.trimmed.nilIfEmpty,
                    lines: [line]))
            }
        }

        // Say so rather than silently importing a subset: a user whose sheet was cut off must be able
        // to see that it was, and the preview is where they would notice.
        if rows.count > maxRows || truncated {
            warnings.append("The sheet is larger than a program can be, so only the first "
                            + "\(maxPrograms) programs and \(maxLinesPerProgram) exercises each were read.")
        }

        guard !programs.isEmpty else { throw ImportError.empty }
        return LiftProgramImportResult(programs: programs, warnings: warnings)
    }

    // MARK: - Helpers

    private static func isZip(_ data: Data) -> Bool {
        data.count >= 4 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4B
    }

    /// Warnings name the SHEET's own row number so the user can go straight to it: the header is
    /// row 1, so the first data row is row 2.
    private static func rowMessage(_ i: Int, _ text: String) -> String {
        "Row \(i + 2): \(text)"
    }

    private static func value(_ row: [String: String], _ keys: [String]) -> String? {
        for k in keys {
            if let v = row[k], !v.trimmed.isEmpty { return v }
        }
        return nil
    }

    private static func intValue(_ row: [String: String], _ keys: [String]) -> Int? {
        guard let raw = value(row, keys) else { return nil }
        return doubleFrom(raw).map { Int($0.rounded()) }
    }

    private static func doubleValue(_ row: [String: String], _ keys: [String]) -> Double? {
        guard let raw = value(row, keys) else { return nil }
        return doubleFrom(raw)
    }

    /// Numbers as spreadsheets actually write them: "60", "60.5", "60,5" (comma decimal in most of
    /// Europe), "60 kg", "2 min". Anything with no digits at all is nil rather than 0 — a blank cell
    /// means "not planned", and 0 would be a planned zero.
    static func doubleFrom(_ raw: String) -> Double? {
        var cleaned = ""
        var seenSeparator = false
        for ch in raw {
            if ch.isNumber { cleaned.append(ch) }
            else if (ch == "." || ch == ",") && !seenSeparator && !cleaned.isEmpty {
                cleaned.append(".")
                seenSeparator = true
            } else if ch == "-" && cleaned.isEmpty {
                cleaned.append(ch)
            }
        }
        guard cleaned.contains(where: { $0.isNumber }) else { return nil }
        return Double(cleaned)
    }
}

extension LiftMuscle {
    /// Resolve a muscle written by a person in a spreadsheet.
    ///
    /// Accepts the stored token (`frontDelts`) and the English display name ("Front delts"), and is
    /// insensitive to case, spaces, hyphens and underscores — so "front delts", "Front-Delts" and
    /// "FRONTDELTS" all land on the same case. Deliberately NOT fuzzy beyond that: the muscle
    /// vocabulary is a stored-data contract, and guessing that "shoulders" means front delts would
    /// silently put sets in a bucket the user did not choose.
    init?(sheetName raw: String) {
        let key = raw.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        guard !key.isEmpty else { return nil }
        for m in LiftMuscle.allCases where m.rawValue.lowercased() == key {
            self = m
            return
        }
        // The English display names, which is what the shipped template's dropdown offers.
        let byName: [String: LiftMuscle] = [
            "chest": .chest, "frontdelts": .frontDelts, "sidedelts": .sideDelts,
            "reardelts": .rearDelts, "triceps": .triceps, "lats": .lats,
            "upperback": .upperBack, "traps": .traps, "biceps": .biceps,
            "forearms": .forearms, "quads": .quads, "hamstrings": .hamstrings,
            "glutes": .glutes, "adductors": .adductors, "abductors": .abductors,
            "calves": .calves, "abs": .abs, "obliques": .obliques,
            "lowerback": .lowerBack, "neck": .neck,
        ]
        guard let m = byName[key] else { return nil }
        self = m
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
