package com.noop.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
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
 * paragraphs, **bold** for key numbers, *italics*, `code`, `###` headings, and bullet/numbered lists —
 * exactly the block + inline set handled here. Anything it doesn't recognise (e.g. a rare table) falls
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
