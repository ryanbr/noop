/// Which stage strings mean "awake" in a stored hypnogram.
///
/// The tree carries TWO stage vocabularies, and that is deliberate rather than sloppy:
///
/// - **Segment `stage` strings** (`StageSegment.stage`, hypnogram rows) canonicalise to `"wake"`.
///   `SleepStagerV2` models its own states as `"awake"` internally and renames to `"wake"` on the way
///   out for exactly this reason.
/// - **Minutes-dictionary keys** (`SleepStageTotals`, `SleepWindowReclip`) canonicalise to `"awake"`.
///
/// The bug this exists to close is the dictionary vocabulary reaching a SEGMENT comparison. Imports do
/// not pass through `SleepStagerV2`: Oura's phase table is `["deep","light","rem","awake"]`, and generic
/// wearable JSON carries whatever the source app wrote. A consumer written `stage == "wake"` then
/// silently misfiles those segments, and — worse — `stage != "wake"` counts them as SLEEP.
///
/// Six sites already defended with `case "wake", "awake"` while five did not, which is what makes this
/// a missing shared rule rather than a missing idea.
///
/// The alias rule (which spellings mean wake) has ONE definition — `isWake`. `canonicalStage` folds
/// through it for the consumers that must KEY by stage rather than merely compare. Neither rewrites a
/// stored string: both operate on in-memory values, so no persisted hypnogram changes meaning and
/// neither vocabulary above moves.
public enum SleepStageVocabulary {

    /// True for either spelling of the wake stage, ignoring case and surrounding whitespace.
    ///
    /// Use on a SEGMENT stage string. Minutes dictionaries are keyed `"awake"` by construction and do
    /// not need it.
    public static func isWake(_ stage: String) -> Bool {
        let s = stage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s == "wake" || s == "awake"
    }

    /// A SEGMENT stage label folded to the segment vocabulary's one spelling per class: trimmed,
    /// lowercased, and wake in either spelling becomes `"wake"`. Unknown labels pass through (trimmed,
    /// lowercased) rather than being invented into the vocabulary.
    ///
    /// For in-memory comparison and bucketing ONLY — dictionary keys, confusion-matrix classes, group
    /// keys. Never write its output back to a store: a persisted hypnogram keeps the spelling its
    /// producer chose, for the reasons in the type comment.
    ///
    /// The Kotlin twin of this rule is `com.noop.ui.canonicalStage`, which folds the SAME alias set
    /// (via `SleepStageVocabulary.isWake`) toward `"awake"` instead, because its consumers key the
    /// minutes/colour vocabulary. One alias rule, one canonical spelling per vocabulary — the fold
    /// target is a property of the vocabulary being keyed, not of the rule.
    public static func canonicalStage(_ stage: String) -> String {
        let s = stage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return isWake(s) ? "wake" : s
    }
}
