package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * A small, dependency-free Markdown renderer for the AI Coach's replies (Android twin of the macOS/iOS
 * MarkdownUI Coach view, #149). The Coach is told to emit "simple Markdown, chat-sized": short
 * paragraphs, **bold** for key numbers, *italics*, `code`, `###` headings, bullet/numbered lists, and
 * GFM pipe tables — exactly the block + inline set handled here. Anything else it doesn't recognise falls
 * through as plain text rather than showing raw symbols, which is strictly better than the old verbatim
 * Text() that rendered `**bold**` literally. Styled from the Strand palette/type so it matches the bubble.
 *
 * The inline parser (parseInline) is pure and unit-tested in CoachMarkdownTest; block layout is above.
 */
@Composable
fun CoachMarkdown(text: String, color: Color = Palette.textPrimary) {
    Column {
        val lines = text.replace("\r\n", "\n").split("\n")
        var i = 0
        var firstBlock = true
        while (i < lines.size) {
            // GFM pipe table — spans several lines (header, --- delimiter, body rows), so handle it
            // before the single-line block cases below and advance i past the whole table.
            val parsedTable = parseTable(lines, i)
            if (parsedTable != null) {
                if (!firstBlock) Spacer(Modifier.height(8.dp))
                MarkdownTable(parsedTable.first, color)
                firstBlock = false
                i = parsedTable.second
                continue
            }
            val raw = lines[i]
            val line = raw.trimEnd()
            when {
                line.isBlank() -> Spacer(Modifier.height(6.dp))
                line.startsWith("### ") -> {
                    if (!firstBlock) Spacer(Modifier.height(8.dp))
                    HeadingText(line.removePrefix("### "), 16.sp, color)
                }
                line.startsWith("## ") -> {
                    if (!firstBlock) Spacer(Modifier.height(10.dp))
                    HeadingText(line.removePrefix("## "), 18.sp, color)
                }
                line.startsWith("# ") -> {
                    if (!firstBlock) Spacer(Modifier.height(10.dp))
                    HeadingText(line.removePrefix("# "), 20.sp, color)
                }
                line.startsWith("- ") || line.startsWith("* ") || line.startsWith("+ ") ->
                    BulletItem("•", parseInline(line.drop(2), color), color)
                NUMBERED.matchEntire(line) != null -> {
                    val m = NUMBERED.matchEntire(line)!!
                    BulletItem(m.groupValues[1] + ".", parseInline(m.groupValues[2], color), color)
                }
                else -> androidx.compose.material3.Text(
                    parseInline(line, color), style = NoopType.body, color = color,
                )
            }
            firstBlock = firstBlock && line.isBlank()
            i++
        }
    }
}

private val NUMBERED = Regex("""^(\d+)\.\s+(.*)$""")

/** A single * or _ opens emphasis only at a word boundary with non-space content after, so "3*4" and a
 *  stray "*" stay literal (a simplified CommonMark left-flanking rule). */
private fun emphasisOpensAt(s: String, i: Int): Boolean =
    (i == 0 || s[i - 1].isWhitespace()) && i + 1 < s.length && !s[i + 1].isWhitespace()

@Composable
private fun HeadingText(text: String, size: androidx.compose.ui.unit.TextUnit, color: Color) {
    androidx.compose.material3.Text(
        parseInline(text, color),
        style = NoopType.body.copy(fontSize = size, fontWeight = FontWeight.SemiBold),
        color = color,
    )
}

@Composable
private fun BulletItem(marker: String, content: AnnotatedString, color: Color) {
    Row(modifier = Modifier.padding(start = 2.dp)) {
        androidx.compose.material3.Text(
            marker, style = NoopType.body, color = Palette.textTertiary,
            modifier = Modifier.width(if (marker.length > 2) 22.dp else 14.dp),
        )
        Spacer(Modifier.width(2.dp))
        androidx.compose.material3.Text(content, style = NoopType.body, color = color)
    }
}

/**
 * Inline Markdown → [AnnotatedString]: **bold**, *italic* / _italic_, `code`. A single left-to-right
 * scan; an unterminated marker is emitted as literal text (so stray `*` never eats the rest of a line).
 */
@Suppress("UNUSED_PARAMETER") // `color` kept for call-site clarity + API symmetry with the block parser
fun parseInline(s: String, color: Color): AnnotatedString = buildAnnotatedString {
    var i = 0
    val n = s.length
    fun emitUntil(marker: String, style: SpanStyle): Boolean {
        val close = s.indexOf(marker, startIndex = i + marker.length)
        if (close < 0) return false
        val inner = s.substring(i + marker.length, close)
        if (inner.isEmpty()) return false
        withStyle(style) { append(inner) }
        i = close + marker.length
        return true
    }
    while (i < n) {
        val c = s[i]
        val handled = when {
            c == '*' && i + 1 < n && s[i + 1] == '*' -> emitUntil("**", SpanStyle(fontWeight = FontWeight.Bold))
            c == '*' && emphasisOpensAt(s, i) -> emitUntil("*", SpanStyle(fontStyle = FontStyle.Italic))
            c == '_' && (i + 1 >= n || s[i + 1] != '_') && emphasisOpensAt(s, i) ->
                emitUntil("_", SpanStyle(fontStyle = FontStyle.Italic))
            c == '`' -> emitUntil("`", SpanStyle(fontFamily = FontFamily.Monospace))
            else -> false
        }
        if (!handled) { append(c); i++ }
    }
}

// MARK: - GFM pipe tables (Android twin of the iOS/macOS MarkdownUI table; "Markdown tables on Android"
// from the #132 roadmap). The Coach sometimes answers with a small comparison table ("metric | you |
// typical"); this is the dependency-free Android equivalent. parseTable is pure and unit-tested in
// CoachMarkdownTest; MarkdownTable does the Compose layout (a bordered grid, header in SemiBold over a
// subtle inset, hairline row separators), reusing parseInline so **bold** / `code` inside a cell styles.

/** A parsed GFM pipe table: a header row and zero-or-more body rows. Cell text is RAW Markdown — the
 *  renderer applies [parseInline] per cell so inline styling inside a cell still works. */
data class MdTable(val header: List<String>, val rows: List<List<String>>)

/** A GFM delimiter cell: dashes with an optional leading/trailing colon for alignment (`---`, `:--`, `:-:`). */
private val TABLE_DELIM_CELL = Regex("""^:?-+:?$""")

/** Split a table row into trimmed cells, dropping the empty cells the optional outer pipes create. */
private fun splitTableRow(line: String): List<String> {
    var s = line.trim()
    if (s.startsWith("|")) s = s.substring(1)
    if (s.endsWith("|")) s = s.dropLast(1)
    return s.split("|").map { it.trim() }
}

private fun isTableDelimiterRow(line: String): Boolean {
    val cells = splitTableRow(line)
    return cells.isNotEmpty() && cells.all { TABLE_DELIM_CELL.matches(it) }
}

/**
 * Parse a GFM pipe table starting at lines[start] — a header row, a `---` delimiter row, then body rows
 * until a blank/non-table line — returning the table plus the index of the first line after it, or null
 * if lines[start] doesn't begin a table. The delimiter row is required, so a prose line that merely
 * contains a `|` (or a setext `---` heading underline) is never mistaken for a table.
 */
fun parseTable(lines: List<String>, start: Int): Pair<MdTable, Int>? {
    if (start + 1 >= lines.size) return null
    val headerLine = lines[start]
    val delimLine = lines[start + 1]
    if (!headerLine.contains("|") || !delimLine.contains("|")) return null
    if (!isTableDelimiterRow(delimLine)) return null
    val header = splitTableRow(headerLine)
    val rows = mutableListOf<List<String>>()
    var i = start + 2
    while (i < lines.size && lines[i].isNotBlank() && lines[i].contains("|")) {
        rows.add(splitTableRow(lines[i]))
        i++
    }
    return MdTable(header, rows) to i
}

@Composable
private fun MarkdownTable(table: MdTable, color: Color) {
    val columns = maxOf(table.header.size, table.rows.maxOfOrNull { it.size } ?: 0)
    Column(
        modifier = Modifier
            .padding(vertical = 2.dp)
            .border(1.dp, Palette.hairline, RoundedCornerShape(8.dp)),
    ) {
        MarkdownTableRow(table.header, columns, color, header = true)
        for (row in table.rows) {
            Spacer(Modifier.fillMaxWidth().height(1.dp).background(Palette.hairline))
            MarkdownTableRow(row, columns, color, header = false)
        }
    }
}

@Composable
private fun MarkdownTableRow(cells: List<String>, columns: Int, color: Color, header: Boolean) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .then(if (header) Modifier.background(Palette.surfaceInset) else Modifier),
    ) {
        for (c in 0 until columns) {
            androidx.compose.material3.Text(
                parseInline(cells.getOrElse(c) { "" }, color),
                style = if (header) NoopType.body.copy(fontWeight = FontWeight.SemiBold) else NoopType.body,
                color = color,
                modifier = Modifier.weight(1f).padding(horizontal = 8.dp, vertical = 6.dp),
            )
        }
    }
}
