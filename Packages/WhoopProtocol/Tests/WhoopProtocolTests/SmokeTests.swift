import XCTest
@testable import WhoopProtocol

final class SmokeTests: XCTestCase {
    func testBundledSchemaLoadsAndWiresEveryPacketDecoder() throws {
        // Exercise the loader used by parseFrame, including its post-hook registration. A resource URL
        // alone cannot detect a schema that loads but silently skips a packet's dynamic fields.
        let schema = loadSchema()
        XCTAssertFalse(schema.envelope.isEmpty)
        XCTAssertEqual(Set(schema.packets.keys), [
            "REALTIME_DATA", "REALTIME_RAW_DATA", "HISTORICAL_DATA", "EVENT",
            "COMMAND_RESPONSE", "METADATA", "CONSOLE_LOGS",
        ])

        for (name, packet) in schema.packets {
            XCTAssertEqual(schema.packet(forType: packet.type), packet, name)
            for alias in packet.aliases {
                XCTAssertEqual(schema.packet(forType: alias), packet, "\(name) alias \(alias)")
            }
            let hookName = try XCTUnwrap(packet.post, "\(name) needs its dynamic-field decoder")
            XCTAssertNotNil(postHooks[hookName], "\(name) references an unregistered hook: \(hookName)")
        }
    }
}
