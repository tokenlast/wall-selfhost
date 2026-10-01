import XCTest
@testable import WipeWall

final class WallConfigurationTests: XCTestCase {
    func testRecipientServerIsUsedForMusicBrokerPaths() {
        let server = WallConfiguration.configuredURL(key: "WallServerURL", fallback: "https://wall.example.invalid", info: ["WallServerURL": "https://tablet.example.org"])
        XCTAssertEqual(server.appendingPathComponent("api/device/spotify/search").absoluteString,
                       "https://tablet.example.org/api/device/spotify/search")
        XCTAssertEqual(URL(string: "api/device/spotify/account/status", relativeTo: server.appendingPathComponent(""))?.absoluteURL.absoluteString,
                       "https://tablet.example.org/api/device/spotify/account/status")
    }

    func testMalformedOrCredentialBearingURLsFallBack() {
        for raw in ["http://example.org", "https://name:password@example.org", "https://example.org?token=fixture", "not a URL"] {
            XCTAssertEqual(WallConfiguration.configuredURL(key: "WallServerURL", fallback: "https://wall.example.invalid", info: ["WallServerURL": raw]).absoluteString,
                           "https://wall.example.invalid")
        }
    }
}
