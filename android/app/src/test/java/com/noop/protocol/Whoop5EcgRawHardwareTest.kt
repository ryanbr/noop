package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Kotlin twin of WhoopProtocolTests/Whoop5EcgRawHardwareTests.swift, against the SAME real bytes.
 *
 * The three complete 1584-byte type-47 layout-16 WHOOP MG flash records embedded here came off hardware
 * on 2026-08-06 while the clasp electrodes were held; they are byte-identical to the Swift fixtures. The
 * cross-platform parity contract says the two decoders must agree on stored values, and a synthetic
 * fixture can only prove they agree about an assumption — these bytes prove they agree about the strap.
 *
 * Only the load-bearing assertions are mirrored: the two fixed-size containers (the leads-off block and
 * the sample region), the resolved sample width, and that a populated record is not discarded. The full
 * characterisation (including the header misalignment that is still open, and the 18-bit continuity
 * argument) lives on the Swift side.
 *
 * No scale or unit is claimed for the sample values, and none is applied.
 */
class Whoop5EcgRawHardwareTest {

    /** The payload offset at which the record's numberOfECGSamples lands. NOT PUFFIN_PAYLOAD_START. */
    private val ecgPayloadStart = 17

    /** unix 1786031627 — numberOfLeadsOffSamples == 11, the block exactly full. */
    private val hex11 =
        "aa0128060100cde02f10036a61cd000bae746aeb51010a000100000000ffff00f401834ae78349e98345d5834703834c" +
        "53834814834916834a0d83478e834d3e83510a8351bb834fda834a718347d383447c8344f3834ec6834c158347848348" +
        "87834785834a2d834978834c33834d39834c07834b178352dc83537e8351fb8352968350db835319835048834540834a" +
        "b3834de2834f1b834f0f835133834f31834f1a83515d834e178351f18351a38352628352558352fd834d4c834a698350" +
        "de835762834e80834b218349338349e6835095835228834c578351b6834f53834ff58351f4834dcb834a6f8350dc8352" +
        "658350d9834b2f834ba8834d50834e73834cd2834d3c8356698355e08356508357a48359bb835af9835a5f8353ae8352" +
        "78835bde835c928358c08353a3835693835bae835b7a835c4a835e89835c8a835bb0835f2583608b83610f835ec9835f" +
        "ee83611283606f8363e68361cd836cf583649b835d0783637983654d8360c0835f2883608f835a2c8352e78350f98349" +
        "f18340e5833e90833c878338e0833677832ec9833094833bd28333be833941833e328343d7834d4e83570c8359228362" +
        "0383622283647f83618c8365ce837351836e3e8367e28368fb836cb3836cd5836de9836d8383717a836f7a836dc4836f" +
        "8783726783723c8370828375d0837291836de9836f4583740883785c8373eb837d748376af8374b283745f8371ad8373" +
        "9a83763e8373eb8375d58375b48374f1837c6e838486837fc0837d3b8379cd837402837747837f4e83765783755b837a" +
        "ab8386ab83876b837c6d8375ef8376cc837d41837b33837f4a837f37837c5583811a837d95837b77837cc1837dc88381" +
        "11837c56837883837a32837da8837f2d8381ec837c388382cb838541837fef8378bd8374ac83731f837914837d9f837b" +
        "93837f35837e22838094838290837e6b837b12837dac837fdc838048837fda83808f8380018381ee83822e8384ed8387" +
        "7883836b837f858382428378e3837bf38382e683865183850583810883839283886583840c8388568389b4838af6838e" +
        "148388b783875983893583861883865c838e6283915d838a58838d748391e583904b8393288397618391038391e98390" +
        "e383905f838c82838b178390f683947e83963883963383981d839973839b94839974839894839b0f83952b839453839b" +
        "78839d39839b708399028394bc839038838f648395be839a4a839ad0839f44839c18839b008399a98398ee839bbe839c" +
        "6983967a8392c38396b28396088395218395d1839a16839fe3839e5f83997483948f83974c839afc8396a2839b40839e" +
        "48839aec839903839a8f8399ef839f09839aa58397dc839c9483a4f383a2bd83a3e683a197839a968399c4839821839b" +
        "8c839dd58398488398528394eb839806839b0d839ae2839a388396f1839521838de2839230839a1983a05083a3e58399" +
        "fe83981b83982b8396be83a224839df2839a04839ecc8399c9839671839a6d83953a8396c1839a6583a05483a22e83a1" +
        "3483a2e983a60083997983984883990d839e6b839ee783a030839dc183a0b983a68583a0c483a40583a0c6839f1d839c" +
        "5683a05e83a0ac839d93839bd1839ebc83a53083aa8b83a71083a49883a0ff83a11f83a22f83a5ac83a69983a54383a3" +
        "2b839b30839e0d839e2f83a040839fae839f99839b5b83a93f83aeb383a61783a78683a7d383a88383abf683aa6e83a6" +
        "0383a79983a4cf83a60983a5dd83a7d083a48b83a61683a8c883a88f83a6f683a80a83a8ef83a5b083a73483aa4683a9" +
        "1b83aca583b07883a4be839ed383a1f483a30783a3ea83a79c83a67d83a50383a70383b0c083a64283abfd83aed883a9" +
        "1583ac5783aeea83ad7b83ae2683a99283a64183abca83ac8783aca783b38083b0b183a53183a42a83a7d383a69283a8" +
        "e083ab2983aba083b1d283ad2883a4cd83a62183ab2c83a9fe83a478839d8983a4cb83aca483a393839ede83a2e483ab" +
        "c383a92f83a46083a49983ad4c83ad5083a7a883a53683a59883aa4783a8db83a45583a47183a59383a6ae83ac7c83b0" +
        "1d83ae9783ae7383aba783a80483aaf483b04c83af0c83a95083a77d83a61183a61b83a48383ad7183aed083a8bc0b43" +
        "004300430043004300430043004300430043004300f8fff8fff8fff8fff8fff8fff8fff7fff7fff7fff7ff00313774b4"

    /** unix 1786031642 — numberOfLeadsOffSamples == 10, one slot unused. */
    private val hex10 =
        "aa0128060100cde02f10037961cd001aae746aeb51030a000124000000ffff00f40183f47c83f61983f31b83f42a83f5" +
        "6083f8bc83f3a683f10a83f15883f2d583f71683f45783f58783f26e83f18983efdb83efc483f51583f5e683f6f283f4" +
        "7d83f59e83f76283f59883f66383f1d583f4d783fbbc83f59183f5a083f4f483f5c683f7ab83eed783ecbf83f19083f0" +
        "5a83f1bd83efa383f30b83f48083f00483f37583f3dd83f1e283f0d983f1a983f2f183f0f283f07283ef9983ef5d83f2" +
        "7c83f3ec83f39d83f2e083f01583eece83ed8b83f06883f10383f19683f42983f08b83f35783f30383edae83ec4083ee" +
        "3583f05e83f16083f3f383ee9b83ed5083f03883ecec83ee8d83f31b83eee883eb4883e87883e0e283e9f483f0d183f0" +
        "7f83effe83ed8983eef183e9dd83ea0b83ed9783ef3083eb8883e9ad83f03983f6d983f33c83ee9583eb6a83ee9483f3" +
        "7f83f25483ee0083ee1283ebf383eda583ef0583f05683f3ab83ef1a83f2cb83f45583f48383f0c083eacf83ee5583f2" +
        "9483f16e83ec5c83eaa683ecb583ecd283f0cf83f38983f39183e9c583e7dd83e9f783e8a983e41783e34b83e1cd83df" +
        "1083dde183d17283d22283c94183bfe583c02483bd9d83bfa683c39483c36183bde583c4c783c7ae83d37d83de9783e3" +
        "0683e62283e8bd83e78d83eb4983e8e683e99283eaac83ecac83ed1a83efe083efdc83ecdb83f35483f20983ef6783f2" +
        "8183f56983f26183f40283f82583f44d83eb8d83eb0f83eb3283edc283f80f83fae583f5c183f4f383fc3783fae583f3" +
        "1a83eeea83ff7883fe3583f5e883fac783ff5983f9ae83f60383f7b883fb8d83f9f083feb783fee18003788009ce8006" +
        "f48002a38005f28006ad800522800cb5800f30800ca7800dda8009c68005f18004e180031180093e8010658010918009" +
        "558005f98008da801274800e0e8002648004ce8003d9800b73800dd4800d2680133b800b908004e783f8dc83fabe8004" +
        "a6800c9a80180c8016b280180b80170b801340801a21801d1e801947801acd801ba480177c8020b68022a2802cba802c" +
        "ec802a6b8030688036da8039fd8040a68043f4804868804b7b804463804cec804fdd8058308055be8055618050d5804f" +
        "85804ebc80556e8062e9805ce18058c1805908805632805eca806349805ee6805a13805b86805dd2806925806655805c" +
        "4780587480620580629b8062358062a4806d0c8063c3805b65805f0d805e4e806b00806a8680656c805fbb805851805b" +
        "4b8057f780596a8061a1806570805e02805e7f8063e58065d48061e680613e805f8b805e5e80579b80536c80543c8053" +
        "e4805d83805aee80569880577f80567e805b73805074804fdd8050ec804f74805355804ef2804f46804f52804d718050" +
        "1f804f9b8058a28050758044c5804ccd804f49804f3a804b0e804bd5804da380451580467a804b6a804961804959804a" +
        "26804c118041fc8041458042e38042918045b7804de88047b28044e68041498035ff80359d8038a3803b81803de78042" +
        "8a803b1c8033b68034c6803919803992802fc880334e8036a780350c80397b8041d1803998803d6c8032a68025428033" +
        "74803db9803761803f7980386c802dc0802f2c8035b08033b8803496802935801bac8021d6802e9b802d30802fbe802b" +
        "eb803439802d85802bfe802eb0802fb4802f938030ec802bd0802932802c4680339f802ef5802b368024cc8025e5802a" +
        "ba802a29802b80802f3780362c8034b38031e28033e2802eda80261b8022908024cd8029438023448027d3802e948027" +
        "5a8024088022928029038033dc80330f80290b802fbe8023858016cb8021fe80274f802304801ed68022ff802df38031" +
        "4380318a802c9680240780264a802766802a47802fa8802d808029958028d0801eeb8017d8801f00802854802ab28034" +
        "3b802ff78022b2801e018020fd8029f28023ac8023208019a68019c08021cc8028858025ed801afc800c5b801e09801f" +
        "fa801df4801df08016aa8012598017e2801c9480233a801f6f801d2f8011d080080e8014a2801d018022a98016218005" +
        "0b800589800dde8019cf8020168020a2800e2b8003ac800ba6801956801838800ebe800c68800d218009ee800e4b0a43" +
        "004300430043004300420042004200420042000000f7fff7fff7fff7fff7fff7fff6fff6fff6fff6ff000000fe104255"

    /**
     * unix 1786031625 — the capture's one PARTLY FILLED record, numberOfECGSamples == 245.
     *
     * The first record of the second reading: the empty record before it is at 1786031624 and the first
     * full 500-sample one at 1786031626, so the strap began the reading part-way into this record's
     * second and wrote 245 of the region's 500 slots. Same 1584-byte frame, same leads-off offsets.
     */
    private val hexPartial245 =
        "aa0128060100cde02f10036861cd0009ae746aeb51010a000100000000ffff00f50083ae1e8259e48210008210008210" +
        "008210008210008210008210008210008210008210008210008210008210008210008210008210008210008210008210" +
        "008210008210008210008210008210008210008210008210008210008210008210008210008210008210008210008210" +
        "008210008210008210008210008210008210008210008210008210008210008210008210008210008210008210008210" +
        "00821000821000821000821000821000821000821000821000821000821000821000821000c21000c21000c21000c210" +
        "00c21085c25696c328a5c39fc1c3cda0c3e169c3e9d9c3ecc2c3ec8bc3ec7dc3efd1c3f2d9c3f434c3f49ac3f4c6c3f5" +
        "b0c3f6f2c3f847c3f716c3f7dac3f776c3f66ec3f67fc3f8a3c3f980c3f8cac3f79dc3f85dc3f839c3f747c3f8b7c3f8" +
        "fac3f829c3f964c3f923c3f7cec3fa53c3f88ac3f78dc3f8c2c3f8f0c3f73fc3f763c3f867c3f7d5c3f816c3f99bc3f7" +
        "dfc3f7f2c3f8fbc3f830c3f777c3f800c3f7b3c3f864c3f6fdc3f79ec3f882c3f77ac3f748c3f88ec3f907c3f980c3f7" +
        "f4c3f924c3f8c8c3f856c3f802c3f823c3f903c3f90fc3f950c3fab5c3fa82c3f98ec3f91ac3f8bdc3fb13c3fb7ec3fb" +
        "3fc3fbd5c3fa08c3faf3c3fc74c3fa42c3fa90c3fbd5c3fc54c3fc01c3fcf6c3fb4dc3fc34c3fd5ac3fcccc3fdfac3fd" +
        "40c3fbacc3fb30c3fc65c3fbf4c3fb99c3fb7dc3fbc4c3fc6fc3fcf4c3fbadc3fbcec3fb46c3fb58c3fc58c3fb0bc3f9" +
        "45c3fa54c3fa75c3fa37c3fab2c3fa6cc3faf0c3fab2c3fad5c3fb46c3fb1ac3fc9dc3fbd2c3faa7c3fa98c3fb85c3fd" +
        "b0c3fc78c3fb95c3fab7c3fc94c3fe67c3fe15c3fcffc3fa3bc3fd33c3ff86c00062c001dac0013cc3ff22c3fefcc3ff" +
        "78c3fef1c00077c00148c000a1c00088c0011dc00263c0017ec000d6c002d9c0023cc001c3c00287c00322c00340c003" +
        "18c00460c002eec003e1c0059bc00561c00479c0056cc00640c005e2c00670c0063bc006444005d440043a4002eb4002" +
        "a10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" +
        "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" +
        "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" +
        "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" +
        "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" +
        "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" +
        "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" +
        "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" +
        "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" +
        "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" +
        "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" +
        "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" +
        "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" +
        "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" +
        "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" +
        "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a45" +
        "004400450045004500450045004500460047000000f9fff9fffafffafffafffafffafffafffbfffcff0000009b973d34"

    private fun bytes(h: String): ByteArray =
        ByteArray(h.length / 2) { ((h[it * 2].digitToInt(16) shl 4) or h[it * 2 + 1].digitToInt(16)).toByte() }

    private val frame11 get() = bytes(hex11)
    private val frame10 get() = bytes(hex10)
    private val framePartial get() = bytes(hexPartial245)

    /** 24-bit big-endian field, low 18 bits signed. Measured from these bytes; not a vendor fact. */
    private fun sample18(blob: List<Int>, i: Int): Int {
        val o = i * 3
        var v = ((blob[o] and 0x03) shl 16) or (blob[o + 1] shl 8) or blob[o + 2]
        if (v and 0x20000 != 0) v -= 0x40000
        return v
    }

    /**
     * Regression: a populated real record is NOT discarded, and resolves to width 3. Under the packed
     * reading the count=10 record left a 5-byte remainder against DEFAULT_MAX_PADDING and was rejected
     * outright — 227 of the capture's 351 populated records.
     */
    @Test
    fun populatedRealRecordIsNotDiscarded() {
        for (frame in listOf(frame11, frame10)) {
            assertEquals(1584, frame.size)
            assertEquals(47, frame[8].toInt() and 0xFF)
            assertEquals(16, frame[9].toInt() and 0xFF)
            val payload = Whoop5Ecg.innerPayload(frame, ecgPayloadStart)
            assertNotNull("real capture must pass both CRCs", payload)
            assertEquals(1563, payload!!.size)
            assertEquals(listOf(3), Whoop5Ecg.rawBytesPerSampleCandidates(payload))
            val packet = Whoop5Ecg.decodeRaw(payload)
            assertNotNull(packet)
            assertEquals(500, packet!!.header.numberOfECGSamples)
            assertEquals(1500, packet.rawECGDataRaw.size)
            assertEquals(3, packet.bytesPerSample)
            assertEquals(listOf(0x00), packet.padding)
        }
    }

    /** The full block: eleven valid I and eleven valid Q. */
    @Test
    fun countElevenRecordDecodesElevenOfEach() {
        val payload = Whoop5Ecg.innerPayload(frame11, ecgPayloadStart)!!
        val packet = Whoop5Ecg.decodeRaw(payload, bytesPerSample = 3)!!
        assertEquals(11, packet.numberOfLeadsOffSamples)
        assertEquals(List(11) { 67 }, packet.leadsOffIRaw)
        assertEquals(List(7) { 65528 } + List(4) { 65527 }, packet.leadsOffQRaw)
        assertEquals(
            listOf(-46361, -46615, -47659, -47357, -45997, -47084, -46826, -46579, -47218, -45762, -44790, -44613),
            (0 until 12).map { sample18(packet.rawECGDataRaw, it) },
        )
    }

    /**
     * The partially filled block: ten valid values off the FRONT of each fixed array. The packed reading
     * started Q two bytes early, gaining a spurious leading 0 and losing the tenth real Q value.
     */
    @Test
    fun countTenRecordDecodesTenOfEachWithQAligned() {
        val payload = Whoop5Ecg.innerPayload(frame10, ecgPayloadStart)!!
        val packet = Whoop5Ecg.decodeRaw(payload, bytesPerSample = 3)!!
        assertEquals(10, packet.numberOfLeadsOffSamples)
        assertEquals(listOf(67, 67, 67, 67, 67, 66, 66, 66, 66, 66), packet.leadsOffIRaw)
        assertEquals(
            listOf(65527, 65527, 65527, 65527, 65527, 65527, 65526, 65526, 65526, 65526),
            packet.leadsOffQRaw,
        )
        assertEquals(65526, packet.leadsOffQRaw.last())   // previously lost into the "padding"
        assertEquals(listOf(0x00), packet.padding)
        assertEquals(
            listOf(-2948, -2535, -3301, -3030, -2720, -1860, -3162, -3830, -3752, -3371, -2282, -2985),
            (0 until 12).map { sample18(packet.rawECGDataRaw, it) },
        )
        // 17 + 1500 + 0 + 1 + 22 + 22 + 1 = 1563, with the block charged at its FIXED size.
        assertEquals(0, packet.unusedSampleBytes)
        val accounted = Whoop5Ecg.HEADER_LENGTH + packet.rawECGDataRaw.size + packet.unusedSampleBytes +
            1 + Whoop5Ecg.LEADS_OFF_SLOT_COUNT * 2 + Whoop5Ecg.LEADS_OFF_SLOT_COUNT * 2 +
            packet.padding.size
        assertEquals(payload.size, accounted)
    }

    /**
     * The SAMPLE region is fixed-size too. The partly-filled record is byte-for-byte the same size as a
     * full one, its sample data stops at frame[769] = 34 + 245 * 3, everything from there to the
     * leads-off block is zero, and the block is at the SAME frame offsets as both full records'. Reading
     * the region as exactly `n * bytesPerSample` landed the count byte on a zero at payload[752], read an
     * empty block and left 766 trailing bytes — the last populated record the decoder discarded.
     */
    @Test
    fun partlyFilledRecordDecodesAtTheStreamWidth() {
        assertEquals(1584, framePartial.size)
        assertTrue((769 until 1534).all { framePartial[it].toInt() == 0 })
        assertEquals(10, framePartial[1534].toInt() and 0xFF)

        val payload = Whoop5Ecg.innerPayload(framePartial, ecgPayloadStart)!!
        assertEquals(1563, payload.size)
        assertEquals(0, payload[752])

        val packet = Whoop5Ecg.decodeRaw(payload, bytesPerSample = 3)!!
        assertEquals(245, packet.header.numberOfECGSamples)
        assertEquals(735, packet.rawECGDataRaw.size)       // only the VALID slots are carried
        assertEquals(3, packet.bytesPerSample)
        assertEquals(765, packet.unusedSampleBytes)
        assertEquals(1500, packet.sampleRegionBytes)       // the region every full record carries
        assertEquals(10, packet.numberOfLeadsOffSamples)
        assertEquals(listOf(69, 68, 69, 69, 69, 69, 69, 69, 70, 71), packet.leadsOffIRaw)
        assertEquals(
            listOf(65529, 65529, 65530, 65530, 65530, 65530, 65530, 65530, 65531, 65532),
            packet.leadsOffQRaw,
        )
        assertEquals(listOf(0x00), packet.padding)
        // The blob's ends, verbatim. No encoding claim is made for this record: it is the first half
        // second of a reading and its samples are still settling.
        assertEquals(listOf(0x83, 0xAE, 0x1E), packet.rawECGDataRaw.take(3))
        assertEquals(listOf(0x40, 0x02, 0xA1), packet.rawECGDataRaw.takeLast(3))

        val accounted = Whoop5Ecg.HEADER_LENGTH + packet.rawECGDataRaw.size + packet.unusedSampleBytes +
            Whoop5Ecg.LEADS_OFF_BLOCK_LENGTH + packet.padding.size
        assertEquals(payload.size, accounted)              // 17 + 735 + 765 + 45 + 1
    }

    /**
     * A partly-filled record does NOT determine its own sample WIDTH, and the enumerator says so rather
     * than picking one: 245 samples inside a 1500-byte region fits 3 bytes per sample and 4 alike. The
     * full records are where the width comes from — they resolve unaided (see the test above).
     */
    @Test
    fun partlyFilledRecordReportsItsWidthAsAmbiguous() {
        val payload = Whoop5Ecg.innerPayload(framePartial, ecgPayloadStart)!!
        assertEquals(listOf(3, 4), Whoop5Ecg.rawBytesPerSampleCandidates(payload))
        assertNull(Whoop5Ecg.decodeRaw(payload))
        // 1 and 2 are ruled out by real sample bytes sitting in what they would call unused capacity.
        assertNull(Whoop5Ecg.decodeRaw(payload, bytesPerSample = 1))
        assertNull(Whoop5Ecg.decodeRaw(payload, bytesPerSample = 2))
    }

    /**
     * The block's geometry, read straight off the frame with no decoder involved: the count byte at
     * frame[1534], I slots at frame[1535], Q slots at frame[1557] — the SAME offsets under both counts,
     * which is what identifies the block as fixed rather than packed.
     */
    @Test
    fun leadsOffBlockIsAtTheSameFixedOffsetsUnderBothCounts() {
        assertEquals(11, Whoop5Ecg.LEADS_OFF_SLOT_COUNT)
        assertEquals(11, frame11[1534].toInt() and 0xFF)
        assertEquals(10, frame10[1534].toInt() and 0xFF)

        fun slots(frame: ByteArray, start: Int) = (0 until 11).map {
            (frame[start + it * 2].toInt() and 0xFF) or ((frame[start + it * 2 + 1].toInt() and 0xFF) shl 8)
        }
        assertEquals(List(11) { 67 }, slots(frame11, 1535))
        assertEquals(List(7) { 65528 } + List(4) { 65527 }, slots(frame11, 1557))
        assertEquals(listOf(67, 67, 67, 67, 67, 66, 66, 66, 66, 66, 0), slots(frame10, 1535))
        assertEquals(
            listOf(65527, 65527, 65527, 65527, 65527, 65527, 65526, 65526, 65526, 65526, 0),
            slots(frame10, 1557),
        )
        assertEquals(frame10.size, 1579 + 1 + 4)
    }
}
