package com.noop.widget

import java.util.Locale

/**
 * Counters for what the home-screen widgets actually cost, so "the widget drains my battery" is
 * decidable from an export instead of being argued from the code.
 *
 * The question that prompted this: the HR widget is the only one that ships a BITMAP. The other two
 * send a few KB of text as RemoteViews; the trace image is sized up to [HrTrace.MAX_BITMAP_BYTES] and
 * crosses a Binder transaction to the launcher on every push. Same cadence, a very different payload,
 * and until now nothing measured either.
 *
 * What is deliberately counted, and why each one is needed to answer it:
 *
 *  - **admitted vs gated pushes** — [PushGate] is supposed to collapse a ~1/s live-HR stream to about
 *    one push a minute. If the gated count is not vastly larger than the admitted one, the throttle is
 *    not doing its job and nothing downstream matters.
 *  - **renders and bytes** — the actual Binder payload. `bytes / renders` is the mean bitmap, and the
 *    total is what a day of streaming costs.
 *  - **skipped renders** — a null-HR push appends no point, so the trace is unchanged and the redraw
 *    produces an identical bitmap. Counting these sizes the cheapest available saving before anyone
 *    writes the code to take it.
 *  - **render time** — separates "the drawing is expensive" from "the transfer is expensive". They
 *    have different fixes and the numbers cannot be guessed apart.
 *
 * Process-lifetime counters, reset when the process dies, reported as a rate over [uptimeMs] so a
 * short session and a long one are comparable. Not persisted: a per-push disk write to measure the
 * cost of pushes would be its own answer to the question.
 *
 * Cheap enough to leave always on. Every field is an increment on a path that already does IPC.
 */
object WidgetTelemetry {

    private var startedAtMs = 0L
    private var pushesAdmitted = 0L
    private var pushesGated = 0L
    private var renders = 0L
    private var rendersRedundant = 0L
    private var renderBytes = 0L
    private var renderMs = 0L
    private var renderMsMax = 0L
    private var pushesUnchanged = 0L
    private var lastPushAtMs = 0L

    /** A push [PushGate] let through: prefs written and every placed widget recomposed. */
    @Synchronized
    fun notePushAdmitted(nowMs: Long) {
        if (startedAtMs == 0L) startedAtMs = nowMs
        pushesAdmitted += 1
        lastPushAtMs = nowMs
    }

    /** A push the gate dropped. At live-HR cadence this should dwarf the admitted count. */
    @Synchronized
    fun notePushGated(nowMs: Long) {
        if (startedAtMs == 0L) startedAtMs = nowMs
        pushesGated += 1
    }

    /**
     * A push [PushGate] admitted but [RenderedGate] then dropped, because nothing the widgets display
     * had changed. Counted separately from a gated push: this is the saving the rendered gate takes,
     * and it needs to be visible to justify keeping it.
     */
    @Synchronized
    fun notePushUnchanged() {
        pushesUnchanged += 1
    }

    /** One trace bitmap built: [bytes] is what crosses the Binder, [elapsedMs] is the draw alone. */
    @Synchronized
    fun noteRender(bytes: Int, elapsedMs: Long) {
        renders += 1
        renderBytes += bytes.toLong()
        renderMs += elapsedMs
        if (elapsedMs > renderMsMax) renderMsMax = elapsedMs
    }

    /**
     * A redraw whose trace had not advanced since the previous one, so it produced an identical
     * bitmap. Counted, not avoided — see the class doc.
     */
    @Synchronized
    fun noteRedundantRender() {
        rendersRedundant += 1
    }

    /** Immutable read for the report. */
    @Synchronized
    fun snapshot(nowMs: Long): Snapshot = Snapshot(
        uptimeMs = if (startedAtMs == 0L) 0L else nowMs - startedAtMs,
        pushesAdmitted = pushesAdmitted,
        pushesGated = pushesGated,
        pushesUnchanged = pushesUnchanged,
        renders = renders,
        rendersRedundant = rendersRedundant,
        renderBytes = renderBytes,
        renderMs = renderMs,
        renderMsMax = renderMsMax,
        lastPushAgoMs = if (lastPushAtMs == 0L) null else nowMs - lastPushAtMs,
    )

    @Synchronized
    fun resetForTest() {
        startedAtMs = 0L; pushesAdmitted = 0L; pushesGated = 0L; pushesUnchanged = 0L
        renders = 0L; rendersRedundant = 0L; renderBytes = 0L; renderMs = 0L; renderMsMax = 0L
        lastPushAtMs = 0L
    }

    data class Snapshot(
        val uptimeMs: Long,
        val pushesAdmitted: Long,
        val pushesGated: Long,
        val pushesUnchanged: Long,
        val renders: Long,
        val rendersRedundant: Long,
        val renderBytes: Long,
        val renderMs: Long,
        val renderMsMax: Long,
        val lastPushAgoMs: Long?,
    ) {
        /** Mean bitmap in bytes, or null before the first render. */
        val meanRenderBytes: Long? get() = if (renders > 0) renderBytes / renders else null

        /**
         * Pushes per hour, extrapolated from this process's uptime. Null under a minute of uptime:
         * a rate from a few seconds of samples is noise wearing a number's clothes.
         */
        val pushesPerHour: Double?
            get() = if (uptimeMs >= 60_000L) pushesAdmitted * 3_600_000.0 / uptimeMs else null

        /**
         * Bitmap bytes per hour at the observed rate — the figure the drain question turns on, since
         * this is what crosses a Binder transaction to the launcher.
         */
        val renderBytesPerHour: Double?
            get() = if (uptimeMs >= 60_000L) renderBytes * 3_600_000.0 / uptimeMs else null

        /**
         * One line for the diagnostics header. Deliberately reports the RATE alongside the raw counts:
         * a total is not comparable between a five-minute session and an all-day one, and comparing
         * sessions is the whole point of collecting this.
         */
        fun render(): String {
            // Renders are checked too: a widget composes from saved prefs when it is placed or after a
            // process start, with no push involved. Reporting "no pushes" there would be true and would
            // silently drop the draw counts, which are the expensive half.
            if (pushesAdmitted == 0L && pushesGated == 0L && renders == 0L) {
                return "Widgets:     no pushes this app session"
            }
            val mins = uptimeMs / 60_000
            val parts = ArrayList<String>(6)
            if (pushesAdmitted > 0L || pushesGated > 0L) {
                parts.add("$pushesAdmitted pushed / ${pushesAdmitted + pushesGated} offered")
            } else {
                parts.add("no pushes")
            }
            pushesPerHour?.let { parts.add("${String.format(Locale.US, "%.1f", it)}/h") }
            if (renders > 0) {
                parts.add("$renders trace draw${if (renders == 1L) "" else "s"}")
                meanRenderBytes?.let { parts.add("mean ${it / 1024}KB") }
                renderBytesPerHour?.let { parts.add("${String.format(Locale.US, "%.1f", it / 1_048_576.0)}MB/h") }
                parts.add("draw ${renderMs / renders}ms avg / ${renderMsMax}ms max")
            }
            if (pushesUnchanged > 0) parts.add("$pushesUnchanged unchanged")
            if (rendersRedundant > 0) parts.add("$rendersRedundant redundant")
            return "Widgets:     ${parts.joinToString(" · ")} (over ${mins}m)"
        }
    }
}

/**
 * Remembers just enough about the last trace drawn to recognise the next one as identical.
 *
 * A signature, never the bitmap: the point is to MEASURE how often a redraw is redundant without
 * retaining half a megabyte to prove it. Holding the image is the optimisation, and it carries a
 * memory trade this change deliberately does not take.
 *
 * The signature covers everything the drawing depends on, not just the series: a size change or a
 * theme flip produces a genuinely different bitmap from the same points, and counting that as
 * redundant would overstate the saving on offer.
 *
 * Kept PER WIDGET INSTANCE. A single shared slot was wrong in the way that matters most here: with
 * two HR widgets placed, each draw would clobber the other's signature, and two same-sized widgets
 * would make each one's necessary first draw look like a repeat of the other's — inflating the
 * redundancy count, which is exactly the direction that would argue for an optimisation that is not
 * actually available. The map is bounded by the number of placed widgets.
 */
internal object HrTraceSeen {
    private val last = HashMap<String, String>()

    /**
     * True when this draw reproduces this WIDGET's previous one exactly. Records the signature either
     * way. [instance] identifies the placed widget, so two of them cannot answer for each other.
     */
    @Synchronized
    fun repeat(
        instance: String,
        series: List<HrPoint>,
        widthPx: Int,
        heightPx: Int,
        dark: Boolean,
    ): Boolean {
        val newest = series.lastOrNull()
        val sig = "${series.size}|${newest?.ts}|${newest?.bpm}|$widthPx|$heightPx|$dark"
        val same = sig == last[instance]
        last[instance] = sig
        return same
    }

    @Synchronized
    fun resetForTest() { last.clear() }
}
