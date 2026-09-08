package com.noop.protocol

/*
 * Hex.kt - the hex encoder the per-frame diagnostic paths use.
 *
 * `joinToString("") { "%02x".format(it) }` reads well and is fine for a one-off line, but it runs
 * String.format ONCE PER BYTE: each call parses the format string and allocates a Formatter, plus a
 * String per byte for joinToString to concatenate. The captures write one line per frame for the whole
 * offload, and a deep-buffer frame is 2140 bytes, so that is ~2140 Formatter allocations per frame.
 *
 * A nibble lookup into one preallocated CharArray does the same job with a single allocation.
 * Byte-for-byte identical output: lowercase, two digits, no separator.
 */

private val HEX_DIGITS = "0123456789abcdef".toCharArray()

/**
 * Lowercase, two digits per byte, no separator. Identical output to the `%02x` join it replaces.
 *
 * NOT named `toHexString`: the stdlib has an `@ExperimentalStdlibApi ByteArray.toHexString()` with the
 * same arity since Kotlin 1.9. An explicit import outranks a default one so ours would still win, but
 * that is a resolution subtlety to be relying on the day the stdlib one stabilises, and both return
 * lowercase unseparated hex, so a silent swap would not fail a single test.
 */
internal fun ByteArray.toHexLower(): String {
    val out = CharArray(size * 2)
    var i = 0
    for (b in this) {
        val v = b.toInt() and 0xFF
        out[i++] = HEX_DIGITS[v ushr 4]
        out[i++] = HEX_DIGITS[v and 0x0F]
    }
    return String(out)
}
