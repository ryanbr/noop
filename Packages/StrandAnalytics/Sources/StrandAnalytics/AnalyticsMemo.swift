import Foundation

// AnalyticsMemo.swift — a tiny, bounded, thread-safe compute cache for the array-heavy analytics
// entry points (v7.0.2 perf hardening, iOS/macOS twin of the Android A1 pass).
//
// WHY THIS EXISTS (#707 — a real OOM on Android, mirrored defensively here): the heavy engines
// (sleep staging, per-day scoring, the history-walking readiness/stress reads) are PURE functions
// that the app calls REPEATEDLY with byte-identical inputs — the post-sync scoring loop re-runs
// them across passes, and a SwiftUI `body` re-evaluation (the iOS equivalent of a Compose
// recompose) re-reads any computed property that calls them. Each call re-allocates large transient
// per-second dictionaries before collapsing to a SMALL result. Recomputing the same night again and
// again is what exhausts the heap, even before any scroll.
//
// The fix mirrors the Android A1 rules EXACTLY:
//   • compute-once-cache: a result is computed at most once per (engine, input-fingerprint);
//   • FULL key: the fingerprint covers every input that can change the output, so distinct inputs
//     never collide onto a stale result (correctness over a marginally smaller key);
//   • BOUNDED: the cache holds at most `capacity` entries and evicts the oldest INSERTION first, so
//     the cache itself can never be the thing that OOMs;
//   • NO retained raw arrays: only the small `Value` result + its `Key` fingerprint are stored — the
//     multi-hour input streams are never held past the call;
//   • invalidate on edit: keys fold in the inputs a user edit changes (e.g. the sleep-V2 toggle,
//     the locked bed/wake window), so an edited night re-keys to a fresh compute, never a stale hit.
//
// Appearance / behaviour are byte-identical: a cache HIT returns the exact value a recompute would,
// and a MISS runs the unchanged engine. This file only adds a lookup in front of pure functions.

/// A bounded, thread-safe memoization cache. `Key` is a cheap value-type fingerprint of the inputs;
/// `Value` is the engine's small result. Eviction is insertion-order (FIFO) once `capacity` is
/// reached — the access pattern here is "the same night/day re-requested", so the hot set stays
/// resident and the cap simply stops unbounded growth across a long session.
final class AnalyticsMemoCache<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [Key: Value] = [:]
    private var order: [Key] = []          // insertion order, for FIFO eviction
    private let capacity: Int

    init(capacity: Int) {
        // At least 1 so the cache is never degenerate; the callers pass small, deliberate caps.
        self.capacity = max(1, capacity)
    }

    /// Return the cached value for `key`, or compute it with `build`, store it (evicting the oldest
    /// entry if at capacity), and return it. `build` runs OUTSIDE the lock so a slow compute never
    /// serialises other engines; a benign duplicate compute under contention is acceptable (the
    /// result is deterministic, and the second writer just overwrites with the identical value).
    func value(_ key: Key, _ build: () -> Value) -> Value {
        lock.lock()
        if let hit = store[key] { lock.unlock(); return hit }
        lock.unlock()

        let computed = build()

        lock.lock()
        if let raced = store[key] {
            // Another thread computed the same key while we were building — keep the existing entry
            // (identical value, deterministic function) rather than re-inserting/re-ordering.
            lock.unlock()
            return raced
        }
        store[key] = computed
        order.append(key)
        if order.count > capacity {
            let evict = order.removeFirst()
            store.removeValue(forKey: evict)
        }
        lock.unlock()
        return computed
    }
}

/// A cheap, allocation-light fingerprint of a sample stream: its count, the first/last timestamps, and a
/// checksum folded over EVERY sample's ts + quantised value. Folding every element is deliberate (#707
/// audit + Android parity): we already walk the stream once to count it, so the full fold is the SAME O(n)
/// — and a strided subset could miss a changed interior sample (two different nights that share count +
/// edge timestamps but differ in the middle would collide onto a STALE cached result). Walking every
/// element costs nothing the count didn't already, and the win we're protecting (not re-running the heavy
/// staging/scoring engines) dwarfs this fold, so correctness wins outright. The Android twin folds every
/// sample identically.
struct StreamFingerprint: Hashable {
    let count: Int
    let firstTs: Int
    let lastTs: Int
    let checksum: UInt64

    /// Build from any sample sequence given a `ts` accessor and a `quant` accessor that maps a sample to an
    /// integer carrying its value (e.g. bpm, or a scaled gravity component). Folds EVERY sample — O(n), the
    /// same order as the `count` it already needs — so no interior change can alias onto a stale entry.
    /// Fold one gravity sample's three axes into a quant value, from their RAW IEEE-754 bits and in
    /// axis order, so two postures sharing a component sum cannot alias (#1453 — the summed
    /// `Int((x + y + z) * 1024)` this replaced aliased (1,0,0), (0,1,0) and (0.5,0.5,0) onto one key,
    /// and returned another window's cached staging).
    ///
    /// Lives here, called by all three stager key sites, because the summed version was duplicated at
    /// each of them and so was wrong at all three at once.
    ///
    /// NOT used by `DaytimeStress`, which folds gravity its own way — a radix-257 packing of ×128
    /// quantised axes (`x &+ y &* 257 &+ z &* 66049`). That one gives each axis a distinct positional
    /// weight, so it never had this aliasing bug and is deliberately left alone: unifying it would change
    /// its keys to no benefit. Checked rather than assumed when this was extracted.
    ///
    /// The mixer is FNV-1a in SHAPE, seeded with this file's existing basis rather than the canonical
    /// 64-bit one — the project's constant is a digit short of it, and `of` and
    /// `ReadinessEngine.rowsFingerprint` have always used it. Consistency beats correcting it: the value
    /// only ever keys an in-process `AnalyticsMemoCache`, never persists, and never crosses the
    /// `.noopbak` boundary, so no external spec depends on the seed. For the same reason it need NOT
    /// equal the Kotlin twin, which mixes multiply-add — a fingerprint that differs across platforms can
    /// only cost one of them a recompute, never change a value.
    static func gravityQuant(x: Double, y: Double, z: Double) -> Int {
        var bits = (fnvBasis ^ x.bitPattern) &* fnvPrime
        bits = (bits ^ y.bitPattern) &* fnvPrime
        bits = (bits ^ z.bitPattern) &* fnvPrime
        return Int(bitPattern: UInt(bits))
    }

    /// This file's long-standing fold seed. NOT the canonical FNV-1a 64-bit offset basis
    /// (14695981039346656037) — it is that value with the trailing digit dropped. Kept because every
    /// fingerprint here has always used it and none of them leave the process; named so the next reader
    /// does not have to re-derive that it is deliberate.
    static let fnvBasis: UInt64 = 1469598103934665603
    /// The canonical FNV-1a 64-bit prime, which this one IS.
    static let fnvPrime: UInt64 = 1099511628211

    static func of<S: Collection>(_ samples: S, ts: (S.Element) -> Int,
                                  quant: (S.Element) -> Int) -> StreamFingerprint {
        var count = 0
        var firstTs = 0, lastTs = 0
        var sum: UInt64 = fnvBasis
        for e in samples {
            let t = ts(e)
            if count == 0 { firstTs = t }
            lastTs = t
            count += 1
            sum = (sum ^ UInt64(bitPattern: Int64(t))) &* fnvPrime
            sum = (sum ^ UInt64(bitPattern: Int64(quant(e)))) &* fnvPrime
        }
        if count == 0 { return StreamFingerprint(count: 0, firstTs: 0, lastTs: 0, checksum: 0) }
        return StreamFingerprint(count: count, firstTs: firstTs, lastTs: lastTs, checksum: sum)
    }

}
