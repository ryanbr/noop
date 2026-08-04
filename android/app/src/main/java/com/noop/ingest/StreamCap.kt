package com.noop.ingest

import java.io.ByteArrayOutputStream
import java.io.InputStream

/**
 * Read a whole stream into memory, refusing to exceed [cap] bytes.
 *
 * The memory-exhaustion guard for user-supplied import files: a `content://` URI or a zip entry can
 * claim any size it likes, and every importer reads the whole thing before parsing. Without a ceiling
 * a malicious or merely broken file takes the process down with an OOM.
 *
 * This existed FIVE times — `ActivityFileImporter`, `NutritionCsvImporter`, `LiftingImporter`,
 * `LabMarkerCsvImport` and `WearableExportImporter` — with identical bodies under two different names
 * (`readCapped` / `readCappedBytes`) and two different shapes (extension / member). Each carried a
 * comment noting that the twins elsewhere "are not visible here", so the duplication was known rather
 * than accidental. A guard is the wrong thing to keep five copies of: a fix or a hardening lands on one
 * and misses four.
 *
 * The CAP itself is deliberately NOT centralised. It is policy, and it legitimately differs by file
 * type — 32 MB for a lab-marker CSV against 512 MB for a Xiaomi zip entry. Each importer keeps its own
 * constant and passes it here; only the mechanism is shared.
 *
 * [what] names the thing in the failure message so the wording each importer already produced is
 * preserved exactly — "Input exceeds …" everywhere except the zip-entry path, which says "Entry".
 *
 * `internal`, not public: every copy this replaces was file-private, and nothing outside
 * `com.noop.ingest` calls it. Kotlin has no package-private, so `internal` is the tightest scope that
 * still lets the five importers and the unit tests reach it — widening a private helper to public API
 * would be an unrelated change riding along with a refactor.
 *
 * @throws IllegalStateException as soon as the running total passes [cap] — before the offending chunk
 *   is buffered, so the peak allocation stays bounded by the cap rather than the file.
 */
internal fun InputStream.readCapped(cap: Long, what: String = "Input"): ByteArray {
    val buffer = ByteArrayOutputStream(64 * 1024)
    val chunk = ByteArray(64 * 1024)
    var total = 0L
    while (true) {
        val n = read(chunk)
        if (n < 0) break
        total += n
        if (total > cap) throw IllegalStateException("$what exceeds $cap bytes")
        buffer.write(chunk, 0, n)
    }
    return buffer.toByteArray()
}
