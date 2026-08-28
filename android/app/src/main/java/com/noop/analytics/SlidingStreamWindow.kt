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
     */
    private val read: suspend (String, Long, Long) -> List<T>,
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
                val head = read(owner, plan.readFrom, plan.readTo)
                rowsRead += head.size
                if (head.size >= limit) {
                    // A truncated EXTENSION is worse than a truncated buffer: it would leave a hole in the
                    // middle rather than at the end. Discard and read the window whole.
                    val full = read(owner, from, to)
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
                val full = read(owner, from, to)
                rowsRead += full.size
                result = full
                nowTruncated = full.size >= limit
            }
        }
        this.owner = owner
        this.from = from
        this.to = to
        this.truncated = nowTruncated
        this.rows = result
        return result
    }
}
