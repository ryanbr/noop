import XCTest
@testable import WhoopProtocol

/// Characterisation of REAL WHOOP MG ECG flash records against this package's own decoder.
///
/// Unlike `Whoop5EcgTests`, whose fixtures are all synthetic, every byte here came off hardware: two
/// complete 1584-byte type-47 records (layout version 16, `frame[9] == 16`) captured 2026-08-06 while
/// the MG clasp electrodes were held, embedded verbatim as hex. Nothing in this file changes production
/// behaviour — it pins what `Whoop5Ecg` ACTUALLY does when handed these bytes, including the places
/// where what it does is wrong.
///
/// What the records establish, and what they contradict, is written against each assertion. The short
/// version:
///
///   • The `RawLabradorPacket` SHAPE fits end to end — blob, leads-off count, the two leads-off arrays
///     and a padding remainder all land with no unaccounted bytes — but only when the payload is taken
///     from frame offset 17, four bytes earlier than the record's real status header.
///   • `headerLength = 17` is FOUR bytes too long for this record. The header's last nine bytes
///     (`heartKeyProgress` through `numberOfECGSamples`) therefore align correctly at offset 17 and
///     decode real values; the first eight bytes do not, and read the record's unix timestamp and two
///     unmapped bytes instead of signal quality, the four booleans and the two classifier enums.
///   • `defaultMaxPadding = 3` rejects 226 of the 350 populated records in the capture (65%), because
///     the leads-off block is FIXED-SIZE (11 slots each for I and Q) rather than packed to the count.
///   • The sample blob is 3 bytes per sample, and the payload is 18 signed bits big-endian inside that
///     24-bit field — proven here by continuity, not assumed.
final class Whoop5EcgRawHardwareTests: XCTestCase {

    // MARK: - Real captured records

    /// Record at unix 1786031627 — leads connected, `numberOfLeadsOffSamples == 11`.
    /// This is the case whose leads-off block happens to be exactly full, so it is the one the current
    /// decoder accepts.
    private static let recordLeadsOffCount11 = """
    aa0128060100cde02f10036a61cd000bae746aeb51010a000100000000ffff00f401834ae78349e98345d5834703834c
    53834814834916834a0d83478e834d3e83510a8351bb834fda834a718347d383447c8344f3834ec6834c158347848348
    87834785834a2d834978834c33834d39834c07834b178352dc83537e8351fb8352968350db835319835048834540834a
    b3834de2834f1b834f0f835133834f31834f1a83515d834e178351f18351a38352628352558352fd834d4c834a698350
    de835762834e80834b218349338349e6835095835228834c578351b6834f53834ff58351f4834dcb834a6f8350dc8352
    658350d9834b2f834ba8834d50834e73834cd2834d3c8356698355e08356508357a48359bb835af9835a5f8353ae8352
    78835bde835c928358c08353a3835693835bae835b7a835c4a835e89835c8a835bb0835f2583608b83610f835ec9835f
    ee83611283606f8363e68361cd836cf583649b835d0783637983654d8360c0835f2883608f835a2c8352e78350f98349
    f18340e5833e90833c878338e0833677832ec9833094833bd28333be833941833e328343d7834d4e83570c8359228362
    0383622283647f83618c8365ce837351836e3e8367e28368fb836cb3836cd5836de9836d8383717a836f7a836dc4836f
    8783726783723c8370828375d0837291836de9836f4583740883785c8373eb837d748376af8374b283745f8371ad8373
    9a83763e8373eb8375d58375b48374f1837c6e838486837fc0837d3b8379cd837402837747837f4e83765783755b837a
    ab8386ab83876b837c6d8375ef8376cc837d41837b33837f4a837f37837c5583811a837d95837b77837cc1837dc88381
    11837c56837883837a32837da8837f2d8381ec837c388382cb838541837fef8378bd8374ac83731f837914837d9f837b
    93837f35837e22838094838290837e6b837b12837dac837fdc838048837fda83808f8380018381ee83822e8384ed8387
    7883836b837f858382428378e3837bf38382e683865183850583810883839283886583840c8388568389b4838af6838e
    148388b783875983893583861883865c838e6283915d838a58838d748391e583904b8393288397618391038391e98390
    e383905f838c82838b178390f683947e83963883963383981d839973839b94839974839894839b0f83952b839453839b
    78839d39839b708399028394bc839038838f648395be839a4a839ad0839f44839c18839b008399a98398ee839bbe839c
    6983967a8392c38396b28396088395218395d1839a16839fe3839e5f83997483948f83974c839afc8396a2839b40839e
    48839aec839903839a8f8399ef839f09839aa58397dc839c9483a4f383a2bd83a3e683a197839a968399c4839821839b
    8c839dd58398488398528394eb839806839b0d839ae2839a388396f1839521838de2839230839a1983a05083a3e58399
    fe83981b83982b8396be83a224839df2839a04839ecc8399c9839671839a6d83953a8396c1839a6583a05483a22e83a1
    3483a2e983a60083997983984883990d839e6b839ee783a030839dc183a0b983a68583a0c483a40583a0c6839f1d839c
    5683a05e83a0ac839d93839bd1839ebc83a53083aa8b83a71083a49883a0ff83a11f83a22f83a5ac83a69983a54383a3
    2b839b30839e0d839e2f83a040839fae839f99839b5b83a93f83aeb383a61783a78683a7d383a88383abf683aa6e83a6
    0383a79983a4cf83a60983a5dd83a7d083a48b83a61683a8c883a88f83a6f683a80a83a8ef83a5b083a73483aa4683a9
    1b83aca583b07883a4be839ed383a1f483a30783a3ea83a79c83a67d83a50383a70383b0c083a64283abfd83aed883a9
    1583ac5783aeea83ad7b83ae2683a99283a64183abca83ac8783aca783b38083b0b183a53183a42a83a7d383a69283a8
    e083ab2983aba083b1d283ad2883a4cd83a62183ab2c83a9fe83a478839d8983a4cb83aca483a393839ede83a2e483ab
    c383a92f83a46083a49983ad4c83ad5083a7a883a53683a59883aa4783a8db83a45583a47183a59383a6ae83ac7c83b0
    1d83ae9783ae7383aba783a80483aaf483b04c83af0c83a95083a77d83a61183a61b83a48383ad7183aed083a8bc0b43
    004300430043004300430043004300430043004300f8fff8fff8fff8fff8fff8fff8fff7fff7fff7fff7ff00313774b4
    """

    /// Record at unix 1786031642 — leads connected, `numberOfLeadsOffSamples == 10`. Structurally
    /// identical, but the one unused leads-off slot pushes the trailing remainder to 5 bytes, which the
    /// default padding tolerance rejects.
    private static let recordLeadsOffCount10 = """
    aa0128060100cde02f10037961cd001aae746aeb51030a000124000000ffff00f40183f47c83f61983f31b83f42a83f5
    6083f8bc83f3a683f10a83f15883f2d583f71683f45783f58783f26e83f18983efdb83efc483f51583f5e683f6f283f4
    7d83f59e83f76283f59883f66383f1d583f4d783fbbc83f59183f5a083f4f483f5c683f7ab83eed783ecbf83f19083f0
    5a83f1bd83efa383f30b83f48083f00483f37583f3dd83f1e283f0d983f1a983f2f183f0f283f07283ef9983ef5d83f2
    7c83f3ec83f39d83f2e083f01583eece83ed8b83f06883f10383f19683f42983f08b83f35783f30383edae83ec4083ee
    3583f05e83f16083f3f383ee9b83ed5083f03883ecec83ee8d83f31b83eee883eb4883e87883e0e283e9f483f0d183f0
    7f83effe83ed8983eef183e9dd83ea0b83ed9783ef3083eb8883e9ad83f03983f6d983f33c83ee9583eb6a83ee9483f3
    7f83f25483ee0083ee1283ebf383eda583ef0583f05683f3ab83ef1a83f2cb83f45583f48383f0c083eacf83ee5583f2
    9483f16e83ec5c83eaa683ecb583ecd283f0cf83f38983f39183e9c583e7dd83e9f783e8a983e41783e34b83e1cd83df
    1083dde183d17283d22283c94183bfe583c02483bd9d83bfa683c39483c36183bde583c4c783c7ae83d37d83de9783e3
    0683e62283e8bd83e78d83eb4983e8e683e99283eaac83ecac83ed1a83efe083efdc83ecdb83f35483f20983ef6783f2
    8183f56983f26183f40283f82583f44d83eb8d83eb0f83eb3283edc283f80f83fae583f5c183f4f383fc3783fae583f3
    1a83eeea83ff7883fe3583f5e883fac783ff5983f9ae83f60383f7b883fb8d83f9f083feb783fee18003788009ce8006
    f48002a38005f28006ad800522800cb5800f30800ca7800dda8009c68005f18004e180031180093e8010658010918009
    558005f98008da801274800e0e8002648004ce8003d9800b73800dd4800d2680133b800b908004e783f8dc83fabe8004
    a6800c9a80180c8016b280180b80170b801340801a21801d1e801947801acd801ba480177c8020b68022a2802cba802c
    ec802a6b8030688036da8039fd8040a68043f4804868804b7b804463804cec804fdd8058308055be8055618050d5804f
    85804ebc80556e8062e9805ce18058c1805908805632805eca806349805ee6805a13805b86805dd2806925806655805c
    4780587480620580629b8062358062a4806d0c8063c3805b65805f0d805e4e806b00806a8680656c805fbb805851805b
    4b8057f780596a8061a1806570805e02805e7f8063e58065d48061e680613e805f8b805e5e80579b80536c80543c8053
    e4805d83805aee80569880577f80567e805b73805074804fdd8050ec804f74805355804ef2804f46804f52804d718050
    1f804f9b8058a28050758044c5804ccd804f49804f3a804b0e804bd5804da380451580467a804b6a804961804959804a
    26804c118041fc8041458042e38042918045b7804de88047b28044e68041498035ff80359d8038a3803b81803de78042
    8a803b1c8033b68034c6803919803992802fc880334e8036a780350c80397b8041d1803998803d6c8032a68025428033
    74803db9803761803f7980386c802dc0802f2c8035b08033b8803496802935801bac8021d6802e9b802d30802fbe802b
    eb803439802d85802bfe802eb0802fb4802f938030ec802bd0802932802c4680339f802ef5802b368024cc8025e5802a
    ba802a29802b80802f3780362c8034b38031e28033e2802eda80261b8022908024cd8029438023448027d3802e948027
    5a8024088022928029038033dc80330f80290b802fbe8023858016cb8021fe80274f802304801ed68022ff802df38031
    4380318a802c9680240780264a802766802a47802fa8802d808029958028d0801eeb8017d8801f00802854802ab28034
    3b802ff78022b2801e018020fd8029f28023ac8023208019a68019c08021cc8028858025ed801afc800c5b801e09801f
    fa801df4801df08016aa8012598017e2801c9480233a801f6f801d2f8011d080080e8014a2801d018022a98016218005
    0b800589800dde8019cf8020168020a2800e2b8003ac800ba6801956801838800ebe800c68800d218009ee800e4b0a43
    004300430043004300420042004200420042000000f7fff7fff7fff7fff7fff7fff6fff6fff6fff6ff000000fe104255
    """

    /// The payload offset at which `EcgStatusHeader`'s `numberOfECGSamples` lands on the record's real
    /// sample count. NOT `Whoop5Ecg.puffinPayloadStart` (11): a type-47 historical record carries a
    /// layout marker at [10], a u32 record index at [11] and a u32 unix second at [15] before its body,
    /// exactly as `decodeWhoop5HistoricalV2021` documents for versions 20/21.
    private static let ecgPayloadStart = 17

    // MARK: - Helpers

    private func hexToBytes(_ h: String) -> [UInt8] {
        var out = [UInt8]()
        var nibble: UInt8?
        for c in h {
            guard let digit = c.hexDigitValue else { continue }
            let v = UInt8(digit)
            if let hi = nibble { out.append(hi << 4 | v); nibble = nil } else { nibble = v }
        }
        return out
    }

    private var frame11: [UInt8] { hexToBytes(Self.recordLeadsOffCount11) }
    private var frame10: [UInt8] { hexToBytes(Self.recordLeadsOffCount10) }

    /// The sample encoding under test: a 24-bit BIG-endian field whose top 6 bits are a tag and whose
    /// low 18 bits are a signed value.
    private func sample18(_ blob: [UInt8], _ i: Int) -> Int {
        let o = i * 3
        var v = (Int(blob[o] & 0x03) << 16) | (Int(blob[o + 1]) << 8) | Int(blob[o + 2])
        if v & 0x20000 != 0 { v -= 0x40000 }
        return v
    }

    /// The rival encoding: byte 0 is an opaque status byte and the value is the trailing 16 bits.
    /// Kept so the continuity test below can actually discriminate rather than merely agree.
    private func sample16(_ blob: [UInt8], _ i: Int) -> Int {
        let o = i * 3
        var v = (Int(blob[o + 1]) << 8) | Int(blob[o + 2])
        if v & 0x8000 != 0 { v -= 0x10000 }
        return v
    }

    private func maxAbsDelta(_ values: [Int]) -> Int {
        var m = 0
        for i in 1..<values.count { m = max(m, abs(values[i] - values[i - 1])) }
        return m
    }

    private func u32le(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    // MARK: - The frames are real and well formed

    func testCapturedFramesPassBothWhoop5CRCs() {
        for frame in [frame11, frame10] {
            XCTAssertEqual(frame.count, 1584)
            XCTAssertEqual(frame[8], 47, "type-47 historical record")
            XCTAssertEqual(frame[9], 16, "layout version 16")
            let check = verifyFrame(frame, family: .whoop5)
            XCTAssertTrue(check.ok, "real capture must pass the CRC16 header and CRC32 trailer")
            XCTAssertEqual(check.length, 1576)
        }
        // The unix second the repo's own v20/v21 header model puts at [15] — this is what makes an ECG
        // status header starting at 17 impossible: bytes 17 and 18 are its two high bytes.
        XCTAssertEqual(u32le(frame11, 15), 1786031627)
        XCTAssertEqual(u32le(frame10, 15), 1786031642)
        XCTAssertEqual(frame11[17], 0x74)
        XCTAssertEqual(frame11[18], 0x6A)
    }

    // MARK: - What upstream concludes about the sample width

    func testRawBytesPerSampleCandidatesResolveToThreeOnRealRecord() {
        guard let payload = Whoop5Ecg.innerPayload(frame11, payloadStart: Self.ecgPayloadStart) else {
            return XCTFail("CRC-gated payload extraction failed on a real frame")
        }
        XCTAssertEqual(payload.count, 1563)
        // Unambiguous: exactly one width survives, and it is 3.
        XCTAssertEqual(Whoop5Ecg.rawBytesPerSampleCandidates(payload: payload), [3])
        XCTAssertNotNil(Whoop5Ecg.decodeRaw(payload: payload),
                        "the disambiguating overload must accept a single-candidate buffer")
    }

    /// The offset is load-bearing, and wrong offsets fail closed rather than producing a plausible decode.
    func testOtherPayloadStartsYieldNoCandidates() {
        for start in [Whoop5Ecg.puffinPayloadStart, 19, 21] {
            guard let payload = Whoop5Ecg.innerPayload(frame11, payloadStart: start) else {
                return XCTFail("payload extraction failed at \(start)")
            }
            XCTAssertEqual(Whoop5Ecg.rawBytesPerSampleCandidates(payload: payload), [],
                           "offset \(start) must not admit any sample width")
        }
    }

    // MARK: - The full RawLabradorPacket shape against real bytes

    func testRawLabradorPacketAccountsForEveryByteOfTheRecord() {
        guard let payload = Whoop5Ecg.innerPayload(frame11, payloadStart: Self.ecgPayloadStart),
              let packet = Whoop5Ecg.decodeRaw(payload: payload, bytesPerSample: 3) else {
            return XCTFail("decodeRaw failed on a real record")
        }
        XCTAssertEqual(packet.header.numberOfECGSamples, 500)
        XCTAssertEqual(packet.rawECGDataRaw.count, 1500)
        XCTAssertEqual(packet.bytesPerSample, 3)
        XCTAssertEqual(packet.numberOfLeadsOffSamples, 11)
        XCTAssertEqual(packet.leadsOffIRaw, [UInt16](repeating: 67, count: 11))
        XCTAssertEqual(packet.leadsOffQRaw,
                       [UInt16](repeating: 65528, count: 7) + [UInt16](repeating: 65527, count: 4))
        XCTAssertEqual(packet.padding, [0x00])

        // Every byte of the 1563-byte payload is claimed by exactly one field.
        let accounted = Whoop5Ecg.headerLength
            + packet.rawECGDataRaw.count
            + 1
            + packet.leadsOffIRaw.count * 2
            + packet.leadsOffQRaw.count * 2
            + packet.padding.count
        XCTAssertEqual(accounted, payload.count, "no unaccounted bytes in the record body")
    }

    // MARK: - Where the header actually is

    /// The nine header bytes from `heartKeyProgress` onward align correctly at offset 17 and carry real
    /// values; the eight before them do not. Both halves are pinned so a future fix has to move both.
    func testHeaderTailIsCorrectAndHeaderHeadIsNot() {
        guard let payload = Whoop5Ecg.innerPayload(frame11, payloadStart: Self.ecgPayloadStart),
              let header = EcgStatusHeader(payload: payload) else {
            return XCTFail("header parse failed")
        }
        // Correctly aligned tail — these agree with the record.
        XCTAssertEqual(header.numberOfECGSamples, 500)
        XCTAssertEqual(header.heartKeyProgress, .percent(0))
        XCTAssertEqual(header.heartKeyHRV, 65535, "0xFFFF unknown sentinel while the reading is running")
        XCTAssertEqual(header.heartKeyAverageHR, 0)
        XCTAssertEqual(header.heartKeyHR, 0)
        XCTAssertEqual(header.heartKeyStressScore, 0)
        XCTAssertEqual(header.heartKeyUnreadableReason, 0)

        // Misaligned head — `signalQualityRaw` and `statusFlags` are the unix timestamp's two high
        // bytes, and the four booleans read unmapped preamble rather than 0/1 flags.
        XCTAssertEqual(header.signalQualityRaw, 0x74, "this is frame[17], a unix byte, not a quality grade")
        XCTAssertEqual(header.signalQuality, .unknown, "116 is outside the 0...3 enum")
        XCTAssertEqual(header.statusFlags, 0x6A, "this is frame[18], the other unix byte")
        XCTAssertEqual(payload[2], 0xEB, "'heartKeyStarted' reads a 235, which is not a Bool")
        XCTAssertEqual(payload[3], 0x51, "'heartKeyIsRunning' reads an 81, which is not a Bool")
    }

    /// The record's real signal-quality and progress bytes, located by their behaviour across the
    /// capture: quality climbs 1 -> 3 and progress ramps 0 -> 100 over the 30-second reading. Progress
    /// at frame[25] is what `EcgStatusHeader` already reads correctly; quality at frame[21] is not.
    func testRealSignalQualityAndProgressBytes() {
        XCTAssertEqual(frame11[21], 1, "signal quality: low, at the start of the reading")
        XCTAssertEqual(frame10[21], 3, "signal quality: high, 15 seconds in")
        XCTAssertEqual(frame11[25], 0, "progress 0%")
        XCTAssertEqual(frame10[25], 36, "progress 36%")
        // The repo's header maps frame[21] onto 'heartKeyIsStoppedAndComplete' — four bytes early.
        guard let payload = Whoop5Ecg.innerPayload(frame11, payloadStart: Self.ecgPayloadStart),
              let header = EcgStatusHeader(payload: payload) else { return XCTFail("header parse failed") }
        XCTAssertTrue(header.heartKeyIsStoppedAndComplete,
                      "reads frame[21] == 1, which is really the signal-quality grade")
    }

    // MARK: - Sample decode

    func testFirstTwelveSamplesDecodeAsSigned18BitBigEndian() {
        guard let payload = Whoop5Ecg.innerPayload(frame11, payloadStart: Self.ecgPayloadStart),
              let packet = Whoop5Ecg.decodeRaw(payload: payload, bytesPerSample: 3) else {
            return XCTFail("decodeRaw failed")
        }
        let blob = packet.rawECGDataRaw
        let first12 = (0..<12).map { sample18(blob, $0) }
        XCTAssertEqual(first12, [-46361, -46615, -47659, -47357, -45997, -47084, -46826, -46579, -47218, -45762, -44790, -44613])

        // Every sample in this record carries tag 0b100000 — leads connected.
        for i in 0..<Int(packet.header.numberOfECGSamples) {
            XCTAssertEqual(blob[i * 3] >> 2, 0b100000, "sample \(i) tag")
        }
    }

    func testSecondRecordFirstTwelveSamples() {
        guard let payload = Whoop5Ecg.innerPayload(frame10, payloadStart: Self.ecgPayloadStart),
              let packet = Whoop5Ecg.decodeRaw(payload: payload, bytesPerSample: 3) else {
            return XCTFail("decodeRaw failed")
        }
        let blob = packet.rawECGDataRaw
        XCTAssertEqual((0..<12).map { sample18(blob, $0) }, [-2948, -2535, -3301, -3030, -2720, -1860, -3162, -3830, -3752, -3371, -2282, -2985])
        let all = (0..<Int(packet.header.numberOfECGSamples)).map { sample18(blob, $0) }
        // 15 seconds into the reading the electrode offset has settled and the trace straddles zero,
        // which is what exercises the sign boundary: the low two bits of byte 0 take both 0b11 and 0b00.
        XCTAssertEqual(all.filter { $0 < 0 }.count, 196)
        XCTAssertEqual(all.filter { $0 >= 0 }.count, 304)
    }

    /// The discriminating evidence for 18 bits over "status byte + 16-bit value".
    ///
    /// In the first record the trace sits on a large negative electrode offset that leaves the 16-bit
    /// signed range. Read as 18 bits it is a continuous waveform; read as a trailing 16-bit value it
    /// wraps full scale between adjacent 500 Hz samples. A 65428-count step between neighbouring samples
    /// of a settling ECG is not physical, so the 18-bit reading is the only one the data supports.
    func testEighteenBitReadingIsContinuousWhereSixteenBitWraps() {
        guard let payload = Whoop5Ecg.innerPayload(frame11, payloadStart: Self.ecgPayloadStart),
              let packet = Whoop5Ecg.decodeRaw(payload: payload, bytesPerSample: 3) else {
            return XCTFail("decodeRaw failed")
        }
        let blob = packet.rawECGDataRaw
        let n = Int(packet.header.numberOfECGSamples)
        let as18 = (0..<n).map { sample18(blob, $0) }
        let as16 = (0..<n).map { sample16(blob, $0) }
        XCTAssertEqual(maxAbsDelta(as18), 3556)
        XCTAssertEqual(maxAbsDelta(as16), 65428)
        XCTAssertLessThan(maxAbsDelta(as18), 8000)
        XCTAssertGreaterThan(maxAbsDelta(as16), 60000)
        // And the 18-bit range genuinely exceeds what 16 signed bits can hold.
        XCTAssertEqual(as18.min(), -53559)
        XCTAssertEqual(as18.max(), -19584)
        XCTAssertLessThan(as18.min()!, -32768)
    }

    // MARK: - The two real defects this capture exposes

    /// 226 of the 350 populated records in the capture carry `numberOfLeadsOffSamples == 10` rather than
    /// 11. The record is a fixed 1584 bytes and the leads-off block is a fixed ELEVEN slots for I and
    /// eleven for Q, so one unused slot leaves five trailing bytes — two over `defaultMaxPadding`. The
    /// triage therefore discards 65% of real records before any field is read.
    func testDefaultPaddingToleranceRejectsTheMajorityOfRealRecords() {
        guard let payload = Whoop5Ecg.innerPayload(frame10, payloadStart: Self.ecgPayloadStart) else {
            return XCTFail("payload extraction failed")
        }
        XCTAssertEqual(Whoop5Ecg.rawBytesPerSampleCandidates(payload: payload), [],
                       "a real, well-formed, CRC-valid record is rejected outright")
        XCTAssertNil(Whoop5Ecg.decodeRaw(payload: payload))
        // Widening the tolerance to the record's actual remainder recovers it, and recovers width 3.
        XCTAssertEqual(Whoop5Ecg.rawBytesPerSampleCandidates(payload: payload, maxPadding: 5), [3])
    }

    /// With the count below the block's capacity, reading Q at `iStart + count * 2` starts two bytes
    /// early: it picks up the unused eleventh I slot as Q[0] and drops the last real Q value. The
    /// leads-off block is fixed-size; the decoder treats it as packed.
    func testLeadsOffQArrayIsShiftedWhenTheBlockIsNotFull() {
        guard let payload = Whoop5Ecg.innerPayload(frame10, payloadStart: Self.ecgPayloadStart),
              let packet = Whoop5Ecg.decodeRaw(payload: payload, bytesPerSample: 3) else {
            return XCTFail("decodeRaw failed")
        }
        XCTAssertEqual(packet.numberOfLeadsOffSamples, 10)
        XCTAssertEqual(packet.leadsOffIRaw, [67, 67, 67, 67, 67, 66, 66, 66, 66, 66])
        // What the decoder produces: a spurious leading zero, and the final value lost.
        XCTAssertEqual(packet.leadsOffQRaw, [0, 65527, 65527, 65527, 65527, 65527, 65527, 65526, 65526, 65526])
        XCTAssertEqual(packet.leadsOffQRaw[0], 0, "the unused eleventh I slot, misread as Q[0]")
        // What the fixed-slot layout actually holds: eleven I slots at frame[1535], eleven Q at [1557].
        let trueQ = (0..<11).map { UInt16(frame10[1557 + $0 * 2]) | UInt16(frame10[1558 + $0 * 2]) << 8 }
        XCTAssertEqual(trueQ, [65527, 65527, 65527, 65527, 65527, 65527, 65526, 65526, 65526, 65526, 0])
        // The five "padding" bytes are not padding: the first two are the tenth real Q value.
        XCTAssertEqual(packet.padding, [246, 255, 0, 0, 0])
        XCTAssertEqual(UInt16(packet.padding[0]) | UInt16(packet.padding[1]) << 8, 65526)
    }
}
