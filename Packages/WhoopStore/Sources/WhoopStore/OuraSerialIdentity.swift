import Foundation

/// What may be written to a SHAREABLE strap log for an Oura ring's serial (#2092).
///
/// Mirrors `WhoopSerialIdentity.logSafe`'s shape exactly (same 3-character prefix + `…`) so a masked
/// WHOOP serial and a masked Oura serial read identically in a shared log — the reader should not need
/// to know which brand a masked id came from to trust it is masked.
///
/// Kept as its OWN type rather than a shared call into `WhoopSerialIdentity`: Oura's serial identity has
/// its own home (`ExperimentalBrand.oura`'s `idPrefix`, `SourceCoordinator.adoptOuraSerial`) and does not
/// share WHOOP's `adoptedId`/`mayAdopt`/`isAlreadyAdopted` machinery — only the LOG-SAFETY shape is
/// common, not the identity model. Kotlin twin: `OuraSerialIdentity`.
public enum OuraSerialIdentity {
    /// The one place the Oura id namespace is spelled, matching `ExperimentalBrand.oura.idPrefix` and
    /// `DeviceBrandCatalog`'s `"oura"` entry — kept here too so `LiveState.redactPii`'s Oura rule and this
    /// masking function agree on the prefix without importing the brand catalog into a pure package.
    public static let idPrefix = "oura"

    /// Never log `"\(idPrefix)-\(serial)"` (or the bare serial) directly — only this.
    public static func logSafe(serial: String?) -> String {
        guard let raw = serial?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return "?" }
        return String(raw.uppercased().prefix(3)) + "…"
    }
}
