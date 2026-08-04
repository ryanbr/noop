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
/// A PREDICATE, deliberately, not a canonicaliser: it fixes the comparisons without rewriting any
/// stored string, so no persisted hypnogram changes meaning and neither vocabulary above moves.
public enum SleepStageVocabulary {

    /// True for either spelling of the wake stage, ignoring case and surrounding whitespace.
    ///
    /// Use on a SEGMENT stage string. Minutes dictionaries are keyed `"awake"` by construction and do
    /// not need it.
    public static func isWake(_ stage: String) -> Bool {
        let s = stage.trimmingCharacters(in: .whitespaces).lowercased()
        return s == "wake" || s == "awake"
    }
}
