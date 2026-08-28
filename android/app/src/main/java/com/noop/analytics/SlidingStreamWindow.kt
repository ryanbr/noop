package com.noop.analytics

/**
 * One stream's backward sliding read buffer for `analyzeRecent`'s pass-1 loop (#1538).
 *
 * [WindowedStreamPlan] decides WHETHER a day's window can reuse what the previous day read; this holds
 * the rows and does the splice. Kept out of the engine because the splice is the part that can silently
 * be wrong — a row dropped here is a scoring input that vanishes — so it gets its own tests rather than
 * living inline in a 1500-line loop. Twin of Swift `SlidingStreamWindow`.
 *
 * The buffer always ends up covering EXACTLY the window just served, never more: the walk runs backwards
 * so the tail above `to` is never asked for again, and holding it would grow the footprint across the
 * pass instead of keeping it at one window. Rows are stored in the store's own `ts ASC` order and an
 * extension is always strictly BELOW the buffer, so prepending preserves that order without a sort.
 *
 * @param tsOf the row's timestamp, in the same unit the window bounds use.
 * @param limit the store's row cap. A read returning [limit] rows was truncated: the queries are
 *   `ORDER BY ts ASC LIMIT`, so truncation silently drops the NEWEST rows, and a buffer built from one
 *   would be missing its tail with nothing to indicate it.
 */
class SlidingStreamWindow<T>(
    private val tsOf: (T) -> Long,
    private val limit: Int,
    /**
     * The store call for `(owner, from, to)`. Bound at CONSTRUCTION rather than passed per call: the two
     * call sites live in `analyzeRecentOnCpu`, which sits close enough to the JVM's 64 KB bytecode ceiling
     * to have a budget test of its own, and a lambda at each call site put it over. It must return
     * `ts ASC` and honour the same [limit].
     *
     * NULL means the read FAILED, which is not the same as returning no rows and must never be cached as
     * if it were. An empty successful read is a true statement about a range — the buffer can serve it,
     * and the next day may splice against it. An empty FAILED read is no statement at all, and caching it
     * would let the following day splice against rows nobody ever fetched, silently dropping the part of
     * its window the buffer claimed to hold. This side never returns null today (a repo read throws, and
     * the throw propagates exactly as it did before the buffer existed); the Swift twin does, because its
     * engine wraps reads in `try?` and turns a failure into an empty array.
     */
    private val read: suspend (String, Long, Long) -> List<T>?,
) {

    private var owner: String? = null
    private var from = 0L
    private var to = 0L
    private var truncated = false
    private var rows: List<T> = emptyList()

    /** Rows this window served from the buffer rather than reading. Diagnostic only.
     *
     *  `Long` here, `Int` on the Swift twin, and that is deliberate rather than drift: each side follows
     *  its own platform's convention for a count, and the value cannot reach either limit — a pass is
     *  bounded by `maxDays` windows of at most [limit] rows, so about 4 M on a 21-day pass. Stated because
     *  a width left to be inferred is how the 32-bit `pct` over-count got in (#1685). */
    var rowsServed = 0L
        private set

    /** Rows this window read from the store. Diagnostic only. Same width note as [rowsServed]. */
    var rowsRead = 0L
        private set

    /**
     * Reads whose RESULT came back at the store's cap, so the newest rows were dropped and the day was
     * scored on an incomplete window. Diagnostic only, but unlike its siblings this one is a correctness
     * signal rather than a savings one: a non-zero count means a number may be wrong, not merely slow.
     *
     * Counted per WINDOW that lost rows, not per pass: once a read is truncated the planner refuses to
     * splice at all, so each later window is a fresh full read and is judged on its own. The truncated-
     * EXTENSION branch below cannot add a second count for one window either, since it only ever re-reads
     * a SUPERSET of what already overran the cap. Pinned by `eachTruncatedWindowCountsSeparately`.
     */
    var truncatedReads = 0L
        private set

    /**
     * The rows for `[from, to]` under [owner], reading as little as the plan allows.
     *
     * The result is byte-for-byte what a direct `read(owner, from, to)` would have returned — that is the
     * whole contract, and the reason every case the planner cannot prove falls back to exactly that call.
     */
    suspend fun rows(owner: String, from: Long, to: Long): List<T> {
        val plan = WindowedStreamPlan.plan(this.owner, this.from, this.to, truncated, owner, from, to)
        val result: List<T>
        val nowTruncated: Boolean
        when (plan) {
            is WindowedStreamPlan.Plan.Serve -> {
                result = rows.filter { tsOf(it) in from..to }
                nowTruncated = false
                rowsServed += result.size
            }
            is WindowedStreamPlan.Plan.Extend -> {
                val head = read(owner, plan.readFrom, plan.readTo) ?: return failedRead()
                rowsRead += head.size
                if (head.size >= limit) {
                    // A truncated EXTENSION is worse than a truncated buffer: it would leave a hole in the
                    // middle rather than at the end. Discard and read the window whole.
                    val full = read(owner, from, to) ?: return failedRead()
                    rowsRead += full.size
                    result = full
                    nowTruncated = full.size >= limit
                } else {
                    // Filtered into ONE list rather than `(head + rows).filter { }`: that form allocates
                    // the concatenation AND the filtered copy, so the splice transiently held roughly
                    // three windows' worth of references on a phone during the cold pass. Same result,
                    // one allocation.
                    val out = ArrayList<T>(head.size + rows.size)
                    for (r in head) if (tsOf(r) in from..to) out.add(r)
                    for (r in rows) if (tsOf(r) in from..to) out.add(r)
                    result = out
                    nowTruncated = false
                    rowsServed += (result.size - head.size).coerceAtLeast(0)
                }
            }
            is WindowedStreamPlan.Plan.FullRead -> {
                val full = read(owner, from, to) ?: return failedRead()
                rowsRead += full.size
                result = full
                nowTruncated = full.size >= limit
            }
        }
        this.owner = owner
        this.from = from
        this.to = to
        this.truncated = nowTruncated
        if (nowTruncated) truncatedReads++
        this.rows = result
        return result
    }

    /** A failed read leaves NO buffer: the next day must go back to the store rather than splice against
     *  a window nobody successfully filled. Returns empty, which is what the caller saw for a failed read
     *  before this class existed. */
    private fun failedRead(): List<T> {
        owner = null
        // The range is cleared too, not just the owner. Leaving it stale would work only because
        // `WindowedStreamPlan.plan` happens to test the owner BEFORE the bounds — a cross-file assumption
        // that holds today and would break silently if those checks were ever reordered. Cheaper to be
        // self-consistent than to depend on the order of someone else's guards.
        from = 0
        to = 0
        rows = emptyList()
        truncated = false
        return emptyList()
    }
}
