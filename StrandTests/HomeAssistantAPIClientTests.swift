import Foundation
import XCTest
import WhoopStore
@testable import Strand

private enum HomeAssistantFakeTransport {
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() { requests = [] }

    static func sender(status: Int) -> (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            requests.append(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
    }
}

final class HomeAssistantAPIClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        HomeAssistantFakeTransport.reset()
    }

    func testConnectionUsesAPIEndpointAndBearerTokenWithoutSendingHealthData() async throws {
        let client = HomeAssistantAPIClient(baseURL: "http://homeassistant.local:8123/ha/",
                                            token: "test-token",
                                            send: HomeAssistantFakeTransport.sender(status: 200))

        try await client.testConnection()

        let request = try XCTUnwrap(HomeAssistantFakeTransport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "http://homeassistant.local:8123/ha/api/")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertNil(request.httpBody)
    }

    func testSetStatePostsHomeAssistantPayloadAndAcceptsCreatedEntity() async throws {
        let client = HomeAssistantAPIClient(baseURL: "https://ha.example.test",
                                            token: "test-token",
                                            send: HomeAssistantFakeTransport.sender(status: 201))

        try await client.setState(.init(entityID: "sensor.noop_recovery", state: "82",
                                        attributes: ["friendly_name": "NOOP Recovery",
                                                     "unit_of_measurement": "%",
                                                     "noop_day": "2026-10-11"]))

        let request = try XCTUnwrap(HomeAssistantFakeTransport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://ha.example.test/api/states/sensor.noop_recovery")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(payload["state"] as? String, "82")
        let attributes = try XCTUnwrap(payload["attributes"] as? [String: String])
        XCTAssertEqual(attributes["friendly_name"], "NOOP Recovery")
        XCTAssertEqual(attributes["unit_of_measurement"], "%")
        XCTAssertEqual(attributes["noop_day"], "2026-10-11")
    }

    func testUnauthorizedResponseSurfacesHomeAssistantStatus() async {
        let client = HomeAssistantAPIClient(baseURL: "https://ha.example.test", token: "bad-token",
                                            send: HomeAssistantFakeTransport.sender(status: 401))

        do {
            try await client.testConnection()
            XCTFail("expected unauthorized response")
        } catch let error as HomeAssistantAPIClient.APIError {
            XCTAssertEqual(error, .response(401))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRejectsUnsafeOrMalformedConfiguration() async {
        XCTAssertTrue(HomeAssistantAPIClient.isValidBaseURL("http://192.168.1.20:8123"))
        XCTAssertTrue(HomeAssistantAPIClient.isValidBaseURL("https://ha.example.test/ha"))
        XCTAssertFalse(HomeAssistantAPIClient.isValidBaseURL("ftp://ha.example.test"))
        XCTAssertFalse(HomeAssistantAPIClient.isValidBaseURL("https://user:pass@ha.example.test"))
        XCTAssertFalse(HomeAssistantAPIClient.isValidBaseURL("https://ha.example.test?token=secret"))

        let client = HomeAssistantAPIClient(baseURL: "https://ha.example.test", token: "token",
                                            send: HomeAssistantFakeTransport.sender(status: 200))
        do {
            try await client.setState(.init(entityID: "sensor.noop_recovery/../../other", state: "82", attributes: [:]))
            XCTFail("expected invalid entity ID")
        } catch let error as HomeAssistantAPIClient.APIError {
            XCTAssertEqual(error, .invalidEntityID)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(HomeAssistantFakeTransport.requests.isEmpty)
    }

    func testPayloadMapsNOOPMetricsToNamedHomeAssistantSensors() {
        let day = DailyMetric(day: "2026-10-11", totalSleepMin: 412.6, efficiency: 0.91,
                              deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                              restingHr: 52, avgHrv: 67.5, recovery: 84, strain: 12.3,
                              exerciseCount: nil, spo2Pct: 97.4, respRateBpm: 15.8,
                              steps: 8_765, skinTempC: 33.2)

        let updates = HomeAssistantPayload.states(day: day, recentHeartRate: 68,
                                                  batterySoc: 78.26, charging: false)
        let byID = Dictionary(uniqueKeysWithValues: updates.map { ($0.entityID, $0) })

        XCTAssertEqual(updates.count, 13)
        XCTAssertEqual(byID["sensor.noop_heart_rate"]?.state, "68")
        XCTAssertEqual(byID["sensor.noop_recovery"]?.state, "84.0")
        XCTAssertEqual(byID["sensor.noop_sleep_duration"]?.state, "413")
        XCTAssertEqual(byID["sensor.noop_sleep_efficiency"]?.state, "91.0")
        XCTAssertEqual(byID["sensor.noop_battery"]?.state, "78.3")
        XCTAssertEqual(byID["sensor.noop_spo2"]?.attributes["unit_of_measurement"] as? String, "%")
        XCTAssertEqual(byID["binary_sensor.noop_strap_charging"]?.state, "off")
        XCTAssertEqual(byID["sensor.noop_recovery"]?.attributes["noop_day"] as? String, "2026-10-11")
    }

    func testPayloadOmitsUnavailableOrNonFiniteMeasurements() {
        let day = DailyMetric(day: "2026-10-11", totalSleepMin: .infinity, efficiency: .nan,
                              deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                              restingHr: nil, avgHrv: .nan, recovery: nil, strain: nil,
                              exerciseCount: nil, spo2Pct: nil, respRateBpm: nil,
                              steps: nil, skinTempC: nil)

        let updates = HomeAssistantPayload.states(day: day, recentHeartRate: nil,
                                                  batterySoc: .infinity, charging: nil)

        XCTAssertTrue(updates.isEmpty)
    }
}
