import Foundation
import XCTest
import AntigravityCore

final class PairingConfigTests: XCTestCase {
    func testParseValidPairingURI() throws {
        let raw = "agymon://pair?url=http%3A%2F%2F192.168.1.42%3A8765%2F&token=secret-token-123&name=Nick%27s%20Workstation"
        let payload = try PairingURI.parse(raw)

        XCTAssertEqual(payload.baseURL.absoluteString, "http://192.168.1.42:8765")
        XCTAssertEqual(payload.token, "secret-token-123")
        XCTAssertEqual(payload.name, "Nick's Workstation")
    }

    func testParsePairingURIDefaultsNameToHostWhenMissing() throws {
        let raw = "agymon://pair?url=https%3A%2F%2Fdevbox.tailnet.ts.net%2Fagy%2F&token=tok_abc"
        let payload = try PairingURI.parse(raw)

        XCTAssertEqual(payload.baseURL.absoluteString, "https://devbox.tailnet.ts.net/agy")
        XCTAssertEqual(payload.token, "tok_abc")
        XCTAssertEqual(payload.name, "devbox.tailnet.ts.net")
    }

    func testBuildAndParseRoundtrip() throws {
        let baseURL = try PairingURI.normalizeBaseURL("http://10.0.0.15:8765/")
        let built = try XCTUnwrap(PairingURI.buildURI(baseURL: baseURL, token: "tok+123/xyz=", name: "Studio Mac"))
        let parsed = try PairingURI.parse(built)

        XCTAssertEqual(parsed.baseURL, baseURL)
        XCTAssertEqual(parsed.token, "tok+123/xyz=")
        XCTAssertEqual(parsed.name, "Studio Mac")
    }

    func testNormalizeBaseURLVariations() throws {
        XCTAssertEqual(try PairingURI.normalizeBaseURL("192.168.1.10:8765").absoluteString, "http://192.168.1.10:8765")
        XCTAssertEqual(try PairingURI.normalizeBaseURL("  HTTP://MyBox.Local:8765///  ").absoluteString, "http://mybox.local:8765")
        XCTAssertEqual(try PairingURI.normalizeBaseURL("https://box.example.com/bridge/?foo=bar#baz").absoluteString, "https://box.example.com/bridge")
        XCTAssertEqual(try PairingURI.normalizeBaseURL("macbook.local").absoluteString, "http://macbook.local")
    }

    func testInvalidPairingURIsThrowExpectedErrors() {
        XCTAssertThrowsError(try PairingURI.parse("https://pair?url=http://localhost:8765&token=abc")) { error in
            XCTAssertEqual(error as? PairingURIError, .unsupportedScheme("https"))
        }

        XCTAssertThrowsError(try PairingURI.parse("agymon://status?url=http://localhost:8765&token=abc")) { error in
            XCTAssertEqual(error as? PairingURIError, .unsupportedAction("status"))
        }

        XCTAssertThrowsError(try PairingURI.parse("agymon://pair?token=abc")) { error in
            XCTAssertEqual(error as? PairingURIError, .missingURL)
        }

        XCTAssertThrowsError(try PairingURI.parse("agymon://pair?url=http%3A%2F%2Flocalhost%3A8765")) { error in
            XCTAssertEqual(error as? PairingURIError, .missingToken)
        }

        XCTAssertThrowsError(try PairingURI.normalizeBaseURL("javascript:alert(1)")) { error in
            XCTAssertEqual(error as? PairingURIError, .unsupportedBaseURLScheme("javascript"))
        }

        XCTAssertThrowsError(try PairingURI.normalizeBaseURL("ftp://192.168.1.2:21")) { error in
            XCTAssertEqual(error as? PairingURIError, .unsupportedBaseURLScheme("ftp"))
        }

        XCTAssertThrowsError(try PairingURI.normalizeBaseURL("   ")) { error in
            XCTAssertEqual(error as? PairingURIError, .invalidBaseURL("   "))
        }
    }

    func testHostProfileDisplayHostAndWebSocketURL() throws {
        let baseURL = try PairingURI.normalizeBaseURL("https://workstation.ts.net:9443")
        let profile = HostProfile(name: "Workstation", baseURL: baseURL)

        XCTAssertEqual(profile.displayHost, "workstation.ts.net:9443")
        XCTAssertEqual(
            profile.websocketURL(token: "abc")?.absoluteString,
            "wss://workstation.ts.net:9443/api/v1/ws?token=abc"
        )
    }

    func testDiscoveredHostSuggestedURL() {
        let fromTXT = DiscoveredHost(
            name: "Mac Studio",
            txtRecord: ["url": "http://192.168.1.77:8765/"]
        )
        XCTAssertEqual(fromTXT.suggestedURL?.absoluteString, "http://192.168.1.77:8765")

        let fromHostPort = DiscoveredHost(
            name: "Dev PC",
            host: "192.168.1.88",
            port: 9000
        )
        XCTAssertEqual(fromHostPort.suggestedURL?.absoluteString, "http://192.168.1.88:9000")

        let fromHostnameTXT = DiscoveredHost(
            name: "Bridge Box",
            txtRecord: ["hostname": "bridge-box.local", "api_version": "1.0"]
        )
        XCTAssertEqual(fromHostnameTXT.suggestedURL?.absoluteString, "http://bridge-box.local:8765")

        let unresolved = DiscoveredHost(name: "Pending Host")
        XCTAssertNil(unresolved.suggestedURL)
    }
}
