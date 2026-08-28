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
    private let read: (String, Int, Int) async -> [T]

    private var owner: String?
    private var from = 0
    private var to = 0
    private var truncated = false
    private var rows: [T] = []

    /// Rows this window served from the buffer rather than reading. Diagnostic only.
    public private(set) var rowsServed = 0
    /// Rows this window read from the store. Diagnostic only.
    public private(set) var rowsRead = 0

    public init(tsOf: @escaping (T) -> Int, limit: Int, read: @escaping (String, Int, Int) async -> [T]) {
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
            let head = await read(owner, readFrom, readTo)
            rowsRead += head.count
            if head.count >= limit {
                // A truncated EXTENSION is worse than a truncated buffer: it would leave a hole in the
                // middle rather than at the end. Discard and read the window whole.
                let full = await read(owner, from, to)
                rowsRead += full.count
                result = full
                nowTruncated = full.count >= limit
            } else {
                let merged = head + rows
                result = merged.filter { tsOf($0) >= from && tsOf($0) <= to }
                nowTruncated = false
                rowsServed += max(0, result.count - head.count)
            }
        case .fullRead:
            let full = await read(owner, from, to)
            rowsRead += full.count
            result = full
            nowTruncated = full.count >= limit
        }
        self.owner = owner
        self.from = from
        self.to = to
        self.truncated = nowTruncated
        self.rows = result
        return result
    }
}
