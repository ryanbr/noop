import XCTest
@testable import WhoopProtocol

/// The archive decision for a WHOOP 5/MG type-47 record must be made on its LAYOUT VERSION, not on
/// what the record happened to decode to.
///
/// `rejectedHistoricalRecords` used to ask only "did this decode to a `unix` plus a
/// `heart_rate`/`gravity_x`?". That screen is the wrong question for a layout NOOP has no field map
/// for: a record from an unmapped version that answered yes was kept NOWHERE — not as rows (nothing
/// mapped it) and not as bytes (it passed the archive filter) — and the strap freed it on the very next
/// trim ack. A record type NOOP has not mapped yet — banked to flash by a newer firmware and pulled
/// back in a later offload — is exactly the shape that can look well-formed enough to pass.
///
/// The screen survived in practice only because of an accident: the unmapped branch of
/// `decodeWhoop5Historical` reads no offsets, so today nothing but `hist_version` ever lands in
/// `parsed` for such a record (`testUnmappedLayoutsDecodeNothingButTheVersionByte` pins that this is
/// true right now). One added static schema field for type 47, or one partially-mapped new version,
/// would silently reopen the hole. These tests pin the version-based decision instead, so the archive
/// no longer depends on that accident holding.
final class UnmappedHistoricalLayoutTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    // A real WHOOP 5/MG type-47 v18 record (from Whoop5HistoricalTests): decodes a real unix, a
    // plausible heart rate and a ~1 g gravity vector — i.e. it PASSES the old decode-outcome screen.
    private let whoop5V18Hex =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"

    /// Re-stamp the WHOOP 5 CRC32 trailer after mutating a payload byte, so the frame stays CRC-VALID.
    /// Load-bearing for every test here: a CRC failure is archived on its own, which would make the
    /// version-based path untestable.
    private func whoop5FrameWithVersion(_ version: UInt8) -> [UInt8] {
        var f = bytes(whoop5V18Hex)
        f[9] = version
        let payloadEnd = f.count - 4
        let c = crc32(f, 8, payloadEnd)
        f[payloadEnd] = UInt8(c & 0xFF)
        f[payloadEnd + 1] = UInt8((c >> 8) & 0xFF)
        f[payloadEnd + 2] = UInt8((c >> 16) & 0xFF)
        f[payloadEnd + 3] = UInt8((c >> 24) & 0xFF)
        return f
    }

    // MARK: - defect: an unmapped layout that decodes real biometrics must still be archived

    /// The headline case. The frame's BYTES are a real v18 record — at the v18 offsets they carry a
    /// valid unix, a plausible heart rate and a ~1 g gravity vector, the exact combination that made
    /// the old screen say "decodable, nothing lost". Only the layout-version byte differs. Whatever
    /// such a record decodes to, its bytes must reach the archive.
    func testUnmappedLayoutIsArchivedEvenThoughItsBytesDecodeCleanlyAsV18() {
        // Precondition: read as its true version, this record decodes everything the old screen wanted.
        let asV18 = parseFrame(bytes(whoop5V18Hex), family: .whoop5)
        XCTAssertEqual(asV18.crcOK, true)
        XCTAssertNotNil(asV18.parsed["unix"], "precondition: these bytes DO decode a unix")
        XCTAssertNotNil(asV18.parsed["heart_rate"], "precondition: these bytes DO decode a heart rate")
        XCTAssertNotNil(asV18.parsed["gravity_x"], "precondition: these bytes DO decode a gravity vector")

        let unmapped = whoop5FrameWithVersion(22)
        XCTAssertEqual(parseFrame(unmapped, family: .whoop5).crcOK, true,
                       "precondition: the record is CRC-VALID, so only the layout decision can archive it")
        XCTAssertTrue(isUnmappedWhoop5HistoricalRecord(unmapped))
        XCTAssertEqual(rejectedHistoricalRecords([unmapped], family: .whoop5), [unmapped],
                       "a record from a layout NOOP cannot map must be archived whatever it decoded")
    }

    /// Every version outside `mappedWhoop5HistoricalVersions` is archived — no gaps, no lucky values.
    func testEveryUnmappedVersionIsArchived() {
        for v in 0...255 where !mappedWhoop5HistoricalVersions.contains(v) {
            let f = whoop5FrameWithVersion(UInt8(v))
            XCTAssertEqual(rejectedHistoricalRecords([f], family: .whoop5), [f],
                           "hist_version \(v) has no field map, so its bytes must be archived")
        }
    }

    // MARK: - lockstep: the version set and the decoder's dispatch cannot drift apart

    /// `mappedWhoop5HistoricalVersions` is the single source of truth for the archive decision, so it
    /// must not claim more (or fewer) versions than `decodeWhoop5Historical` actually maps. Proved from
    /// the decoder's own behaviour: for EVERY version outside the set, the decode yields nothing but
    /// `hist_version` — i.e. the dispatch `switch` has no case the set omits.
    func testUnmappedLayoutsDecodeNothingButTheVersionByte() {
        for v in 0...255 where !mappedWhoop5HistoricalVersions.contains(v) {
            let p = parseFrame(whoop5FrameWithVersion(UInt8(v)), family: .whoop5)
            XCTAssertEqual(p.parsed.keys.sorted(), ["hist_version"],
                           "v\(v) is outside the mapped set but the decoder populated fields for it — "
                               + "the set and the dispatch switch have drifted")
        }
    }

    /// The four mapped versions ARE recognised as mapped (the other direction of the lockstep).
    func testMappedVersionsAreNotTreatedAsUnmapped() {
        XCTAssertEqual(mappedWhoop5HistoricalVersions, [18, 20, 21, 26])
        for v in mappedWhoop5HistoricalVersions {
            XCTAssertFalse(isUnmappedWhoop5HistoricalRecord(whoop5FrameWithVersion(UInt8(v))),
                           "v\(v) has a field map and must not be archived on layout grounds")
        }
    }

    /// A cleanly-decoding v18 record is still NOT archived — widening the screen must not start
    /// archiving the layouts NOOP already understands wholesale.
    func testMappedV18RecordStillNotArchived() {
        XCTAssertTrue(rejectedHistoricalRecords([bytes(whoop5V18Hex)], family: .whoop5).isEmpty)
    }

    /// The layout rule is WHOOP 5-only: it keys off `frame[9]`, which on a WHOOP 4 frame is a payload
    /// byte, not a version. WHOOP 4's unmapped versions go through the schema's validated v24 fallback
    /// (`PostHooks`), which keeps a record only when it decodes to a ~1 g gravity vector and a plausible
    /// HR and otherwise drops the biometrics — so those records reach the archive by the decode-outcome
    /// route and must not be dragged in by this one.
    func testWhoop4FramesAreUnaffectedByTheWhoop5LayoutRule() {
        // A synthetic WHOOP 4 V24 type-47 record (HR=63) that decodes cleanly (from HistoricalV24Tests).
        let v24Hex =
            "aa5a008e2f18000000000000f153650000000000003f0152030000000000000000dc053075" +
            "000000cdcc4c3dcdcccc3d5a657e3f00000040cdcc4c3dcdcccc3d5a657e3f504668428403" +
            "200364006400b80bb80b000000000000c25c1a88"
        XCTAssertTrue(rejectedHistoricalRecords([bytes(v24Hex)], family: .whoop4).isEmpty)
        XCTAssertFalse(isUnmappedWhoop5HistoricalRecord(bytes(v24Hex)),
                       "a WHOOP 4 frame has no type-47 byte at index 8 — the rule must not fire on it")
    }
}
