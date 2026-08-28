import Foundation

/// One stream's backward sliding read buffer for `analyzeRecent`'s pass-1 loop (#1538).
///
/// `WindowedStreamPlan` decides WHETHER a day's window can reuse what the previous day read; this holds
/// the rows and does the splice. Kept out of the engine because the splice is the part that can silently
/// be wrong — a row dropped here is a scoring input that vanishes — so it gets its own tests rather than
/// living inline in a very long loop. Twin of Kotlin `SlidingStreamWindow`.
///
/// The buffer always ends up covering EXACTLY the window just served, never more: the walk runs backwards
/// so the tail above `to` is never asked for again, and holding it would grow the footprint across the
/// pass instead of keeping it at one window. Rows are stored in the store's own `ts ASC` order and an
/// extension is always strictly BELOW the buffer, so prepending preserves that order without a sort.
public final class SlidingStreamWindow<T> {

    private let tsOf: (T) -> Int
    private let limit: Int
    /// The store call for `(owner, from, to)`. Bound at CONSTRUCTION to match the Kotlin twin, where the
    /// two call sites sit inside a method already at its JVM bytecode budget and a per-call lambda put it
    /// over. It must return `ts ASC` and honour the same `limit`.
    ///
    /// `nil` means the read FAILED, which is not the same as returning no rows and must never be cached as
    /// if it were. An empty successful read is a true statement about a range — the buffer can serve it,
    /// and the next day may splice against it. An empty FAILED read is no statement at all, and caching it
    /// would let the following day splice against rows nobody ever fetched, silently dropping the part of
    /// its window the buffer claimed to hold. This side is the one that needs it: the engine wraps its
    /// store reads in `try?`, so a failure arrives here as an empty array unless the caller says otherwise.
    private let read: (String, Int, Int) async -> [T]?

    private var owner: String?
    private var from = 0
    private var to = 0
    private var truncated = false
    private var rows: [T] = []

    /// Rows this window served from the buffer rather than reading. Diagnostic only.
    ///
    /// `Int` here, `Long` on the Kotlin twin, and that is deliberate rather than drift: each side follows
    /// its own platform's convention for a count, and the value cannot reach either limit — a pass is
    /// bounded by `maxDays` windows of at most `limit` rows, so about 4 M on a 21-day pass, which fits
    /// even the 32-bit `Int` of `arm64_32` that this package also builds for. Stated because a width left
    /// to be inferred is how the 32-bit `pct` over-count got in (#1685).
    public private(set) var rowsServed = 0
    /// Rows this window read from the store. Diagnostic only. Same width note as `rowsServed`.
    public private(set) var rowsRead = 0
    /// Reads whose RESULT came back at the store's cap, so the newest rows were dropped and the day was
    /// scored on an incomplete window. Diagnostic only, but unlike its siblings this one is a correctness
    /// signal rather than a savings one: a non-zero count means a number may be wrong, not merely slow.
    ///
    /// Counted per WINDOW that lost rows, not per pass: once a read is truncated the planner refuses to
    /// splice at all, so each later window is a fresh full read and is judged on its own. The truncated-
    /// EXTENSION branch below cannot add a second count for one window either, since it only ever re-reads
    /// a SUPERSET of what already overran the cap. Pinned by `eachTruncatedWindowCountsSeparately`.
    public private(set) var truncatedReads = 0

    public init(tsOf: @escaping (T) -> Int, limit: Int, read: @escaping (String, Int, Int) async -> [T]?) {
        self.tsOf = tsOf
        self.limit = limit
        self.read = read
    }

    /// The rows for `[from, to]` under `owner`, reading as little as the plan allows.
    ///
    /// The result is byte-for-byte what a direct `read(owner, from, to)` would have returned — that is the
    /// whole contract, and the reason every case the planner cannot prove falls back to exactly that call.
    public func rows(owner: String, from: Int, to: Int) async -> [T] {
        let plan = WindowedStreamPlan.plan(cachedOwner: self.owner, cachedFrom: self.from,
                                           cachedTo: self.to, cachedTruncated: truncated,
                                           owner: owner, from: from, to: to)
        let result: [T]
        let nowTruncated: Bool
        switch plan {
        case .serve:
            result = rows.filter { tsOf($0) >= from && tsOf($0) <= to }
            nowTruncated = false
            rowsServed += result.count
        case let .extend(readFrom, readTo):
            guard let head = await read(owner, readFrom, readTo) else { return failedRead() }
            rowsRead += head.count
            if head.count >= limit {
                // A truncated EXTENSION is worse than a truncated buffer: it would leave a hole in the
                // middle rather than at the end. Discard and read the window whole.
                guard let full = await read(owner, from, to) else { return failedRead() }
                rowsRead += full.count
                result = full
                nowTruncated = full.count >= limit
            } else {
                // Filtered into ONE array rather than `(head + rows).filter { }`: that form allocates
                // the concatenation AND the filtered copy, so the splice transiently held roughly three
                // windows' worth of references. Same result, one allocation.
                var out: [T] = []
                out.reserveCapacity(head.count + rows.count)
                for r in head where tsOf(r) >= from && tsOf(r) <= to { out.append(r) }
                for r in rows where tsOf(r) >= from && tsOf(r) <= to { out.append(r) }
                result = out
                nowTruncated = false
                rowsServed += max(0, result.count - head.count)
            }
        case .fullRead:
            guard let full = await read(owner, from, to) else { return failedRead() }
            rowsRead += full.count
            result = full
            nowTruncated = full.count >= limit
        }
        self.owner = owner
        self.from = from
        self.to = to
        self.truncated = nowTruncated
        if nowTruncated { truncatedReads += 1 }
        self.rows = result
        return result
    }

    /// A failed read leaves NO buffer: the next day must go back to the store rather than splice against a
    /// window nobody successfully filled. Returns empty, which is what the caller saw for a failed read
    /// before this class existed.
    private func failedRead() -> [T] {
        owner = nil
        // The range is cleared too, not just the owner. Leaving it stale would work only because
        // `WindowedStreamPlan.plan` happens to test the owner BEFORE the bounds — a cross-file assumption
        // that holds today and would break silently if those checks were ever reordered. Cheaper to be
        // self-consistent than to depend on the order of someone else's guards.
        from = 0
        to = 0
        rows = []
        truncated = false
        return []
    }
}
