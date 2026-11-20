import Foundation
import XCTest
import AntigravityCore

final class BridgeAPIClientTests: XCTestCase {
    private var host: String!
    private var baseURL: URL!
    private var client: BridgeAPIClient!

    override func setUp() {
        super.setUp()
        host = "test-\(UUID().uuidString.lowercased()).local"
        baseURL = URL(string: "http://\(host!):8765")!

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        client = BridgeAPIClient(baseURL: baseURL, token: "test-bearer-token", session: session)
    }

    override func tearDown() {
        if let host {
            MockURLProtocol.removeHandler(forHost: host)
        }
        client = nil
        baseURL = nil
        host = nil
        super.tearDown()
    }

    func testPingDoesNotSendAuthorizationHeader() async throws {
        MockURLProtocol.register(forHost: host) { request, _ in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/ping")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, ["Content-Type": "application/json"], Data(#"{"ok":true,"api_version":"1.0"}"#.utf8))
        }

        let response = try await client.ping()
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.apiVersion, "1.0")
    }

    func testFetchHealthAndSessionsIncludeBearerAuthAndQueryParams() async throws {
        MockURLProtocol.register(forHost: host) { request, _ in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-bearer-token")
            let path = request.url?.path ?? ""
            if path == "/api/v1/health" {
                let json = """
                {
                  "status": "ok",
                  "api_version": "1.0",
                  "hostname": "mini-m4",
                  "platform": "macOS",
                  "uptime_seconds": 3600,
                  "brain_dir": "/tmp/brain",
                  "brain_dir_exists": true,
                  "session_count": 1,
                  "active_session_count": 1,
                  "pending_approval_count": 0,
                  "total_input_tokens": 1000,
                  "total_cache_read_tokens": 3000,
                  "total_output_tokens": 500,
                  "server_time": "2026-11-20T20:35:00Z"
                }
                """
                return (200, ["Content-Type": "application/json"], Data(json.utf8))
            } else if path == "/api/v1/sessions" {
                XCTAssertEqual(request.url?.query, "limit=25")
                let json = """
                {
                  "sessions": [
                    {
                      "id": "s-1",
                      "title": "Demo",
                      "status": "running",
                      "created_at": "2026-11-20T20:00:00Z",
                      "updated_at": "2026-11-20T20:35:00Z",
                      "step_count": 5,
                      "model": "gemini-2.5-pro",
                      "input_tokens": 500,
                      "cache_read_tokens": 1500,
                      "output_tokens": 200,
                      "artifact_count": 1,
                      "task_count": 0,
                      "subagent_count": 0,
                      "has_swarm": false,
                      "last_step_preview": "Running tests"
                    }
                  ]
                }
                """
                return (200, ["Content-Type": "application/json"], Data(json.utf8))
            }
            return (404, [:], Data())
        }

        let health = try await client.fetchHealth()
        XCTAssertEqual(health.hostname, "mini-m4")
        XCTAssertEqual(health.cacheHitRate, 0.75, accuracy: 0.0001)

        let sessions = try await client.fetchSessions(limit: 25)
        XCTAssertEqual(sessions.sessions.count, 1)
        XCTAssertEqual(sessions.sessions[0].id, "s-1")
    }

    func testFetchTranscriptArtifactsTasksAndBinaryMedia() async throws {
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        MockURLProtocol.register(forHost: host) { request, _ in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-bearer-token")
            let url = try XCTUnwrap(request.url)
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            switch url.path {
            case "/api/v1/sessions/sess-1/transcript":
                let queryMap = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(queryMap["since_step"], "3")
                XCTAssertEqual(queryMap["limit"], "50")
                XCTAssertEqual(queryMap["full"], "true")
                let json = """
                {"session_id":"sess-1","total_steps":4,"steps":[]}
                """
                return (200, ["Content-Type": "application/json"], Data(json.utf8))

            case "/api/v1/sessions/sess-1/artifacts":
                let json = """
                {
                  "session_id": "sess-1",
                  "artifacts": [
                    {
                      "name": "plan v1.md",
                      "relative_path": "docs/plan v1.md",
                      "mime_type": "text/markdown",
                      "size_bytes": 128,
                      "updated_at": "2026-11-20T20:35:00Z",
                      "is_image": false
                    }
                  ]
                }
                """
                return (200, ["Content-Type": "application/json"], Data(json.utf8))

            case "/api/v1/sessions/sess-1/artifacts/docs/plan v1.md":
                if url.query == "format=json" {
                    let json = """
                    {"name":"plan v1.md","relative_path":"docs/plan v1.md","mime_type":"text/markdown","content":"# Plan"}
                    """
                    return (200, ["Content-Type": "application/json"], Data(json.utf8))
                }
                return (200, ["Content-Type": "image/png"], pngBytes)

            case "/api/v1/sessions/sess-1/tasks":
                let json = """
                {"session_id":"sess-1","tasks":[],"subagents":[],"swarm_events":[]}
                """
                return (200, ["Content-Type": "application/json"], Data(json.utf8))

            case "/api/v1/sessions/sess-1/media/preview.png":
                return (200, ["Content-Type": "image/png"], pngBytes)

            default:
                return (404, [:], Data())
            }
        }

        let transcript = try await client.fetchTranscript(sessionId: "sess-1", sinceStep: 3, limit: 50, full: true)
        XCTAssertEqual(transcript.totalSteps, 4)

        let artifacts = try await client.fetchArtifacts(sessionId: "sess-1")
        XCTAssertEqual(artifacts.artifacts.first?.id, "docs/plan v1.md")

        let content = try await client.fetchArtifactContent(sessionId: "sess-1", relativePath: "docs/plan v1.md")
        XCTAssertEqual(content.content, "# Plan")

        let binary = try await client.fetchArtifactBinary(sessionId: "sess-1", relativePath: "docs/plan v1.md")
        XCTAssertEqual(binary, pngBytes)

        let tasks = try await client.fetchTasks(sessionId: "sess-1")
        XCTAssertEqual(tasks.sessionId, "sess-1")

        let media = try await client.fetchMediaData(urlPath: "/api/v1/sessions/sess-1/media/preview.png")
        XCTAssertEqual(media, pngBytes)
    }

    func testFetchApprovalsAndSubmitDecision() async throws {
        MockURLProtocol.register(forHost: host) { request, bodyData in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-bearer-token")
            if request.httpMethod == "GET" && request.url?.path == "/api/v1/approvals" {
                let json = """
                {
                  "approvals": [
                    {
                      "id": "appr-42",
                      "session_id": "sess-1",
                      "hook_event": "PreToolUse",
                      "tool_name": "run_command",
                      "args_json": "{\\"cmd\\":\\"swift test\\"}",
                      "summary": "Run tests",
                      "status": "pending",
                      "created_at": "2026-11-20T20:35:00Z",
                      "expires_at": "2026-11-20T20:35:55Z",
                      "decision": null,
                      "decision_reason": null,
                      "decided_at": null
                    }
                  ]
                }
                """
                return (200, ["Content-Type": "application/json"], Data(json.utf8))
            }

            if request.httpMethod == "POST" && request.url?.path == "/api/v1/approvals/appr-42/decide" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                let data = try XCTUnwrap(bodyData)
                let payload = try BridgeJSONDecoder.decode(ApprovalDecisionPayload.self, from: data)
                XCTAssertEqual(payload.decision, .deny)
                XCTAssertEqual(payload.reason, "Not on production")

                let responseJSON = """
                {
                  "id": "appr-42",
                  "session_id": "sess-1",
                  "hook_event": "PreToolUse",
                  "tool_name": "run_command",
                  "args_json": "{\\"cmd\\":\\"swift test\\"}",
                  "summary": "Run tests",
                  "status": "denied",
                  "created_at": "2026-11-20T20:35:00Z",
                  "expires_at": "2026-11-20T20:35:55Z",
                  "decision": "deny",
                  "decision_reason": "Not on production",
                  "decided_at": "2026-11-20T20:35:10Z"
                }
                """
                return (200, ["Content-Type": "application/json"], Data(responseJSON.utf8))
            }

            return (404, [:], Data())
        }

        let list = try await client.fetchApprovals()
        XCTAssertEqual(list.approvals.count, 1)
        XCTAssertEqual(list.approvals[0].id, "appr-42")

        let decided = try await client.submitApprovalDecision(
            approvalId: "appr-42",
            decision: .deny,
            reason: "Not on production"
        )
        XCTAssertEqual(decided.status, .denied)
        XCTAssertEqual(decided.decision, .deny)
        XCTAssertEqual(decided.decisionReason, "Not on production")
        XCTAssertNotNil(decided.decidedAt)
    }

    func testHTTPStatusErrorMapping() async {
        MockURLProtocol.register(forHost: host) { _, _ in
            (401, ["Content-Type": "application/json"], Data(#"{"error":"invalid token"}"#.utf8))
        }
        do {
            _ = try await client.fetchHealth()
            XCTFail("Expected unauthorized error")
        } catch let error as BridgeAPIError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        MockURLProtocol.register(forHost: host) { _, _ in
            (409, ["Content-Type": "application/json"], Data(#"{"error":"already decided"}"#.utf8))
        }
        do {
            _ = try await client.submitApprovalDecision(approvalId: "appr-1", decision: .allow)
            XCTFail("Expected conflict error")
        } catch let error as BridgeAPIError {
            XCTAssertEqual(error, .conflict("already decided"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        MockURLProtocol.register(forHost: host) { _, _ in
            (404, ["Content-Type": "application/json"], Data(#"{"detail":"missing session"}"#.utf8))
        }
        do {
            _ = try await client.fetchArtifacts(sessionId: "unknown")
            XCTFail("Expected notFound error")
        } catch let error as BridgeAPIError {
            XCTAssertEqual(error, .notFound("missing session"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        MockURLProtocol.register(forHost: host) { _, _ in
            (200, ["Content-Type": "application/json"], Data("not-json".utf8))
        }
        do {
            _ = try await client.fetchHealth()
            XCTFail("Expected decodingFailed error")
        } catch let error as BridgeAPIError {
            if case .decodingFailed = error {
                // Expected
            } else {
                XCTFail("Expected decodingFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testProtocolExtensionConvenienceOverloadsAreUnambiguous() async throws {
        MockURLProtocol.register(forHost: host) { request, _ in
            let url = try XCTUnwrap(request.url)
            switch url.path {
            case "/api/v1/sessions":
                XCTAssertEqual(url.query, "limit=50")
                return (200, ["Content-Type": "application/json"], Data(#"{"sessions":[]}"#.utf8))
            case "/api/v1/sessions/sess-default/transcript":
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let queryMap = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(queryMap["since_step"], "0")
                XCTAssertEqual(queryMap["limit"], "200")
                XCTAssertEqual(queryMap["full"], "false")
                return (200, ["Content-Type": "application/json"], Data(#"{"session_id":"sess-default","total_steps":0,"steps":[]}"#.utf8))
            case "/api/v1/sessions/sess-default/media/raw.bin":
                return (200, ["Content-Type": "application/octet-stream"], Data([0x01, 0x02]))
            default:
                return (404, [:], Data())
            }
        }

        let protocolClient: any BridgeAPIClientProtocol = client
        let sessions = try await protocolClient.fetchSessions()
        XCTAssertTrue(sessions.sessions.isEmpty)

        let transcript = try await client.fetchTranscript(sessionId: "sess-default")
        XCTAssertEqual(transcript.sessionId, "sess-default")

        let binary = try await protocolClient.fetchBinary(path: "/api/v1/sessions/sess-default/media/raw.bin")
        XCTAssertEqual(binary, Data([0x01, 0x02]))
    }
}

// MARK: - Thread-Safe MockURLProtocol

private final class MockURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest, Data?) throws -> (Int, [String: String], Data)

    private static let registry = MockHandlerRegistry()

    static func register(forHost host: String, handler: @escaping Handler) {
        registry.set(handler, forHost: host)
    }

    static func removeHandler(forHost host: String) {
        registry.remove(forHost: host)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let handler = Self.registry.handler(forHost: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let bodyData = Self.readBody(from: request)
            let (statusCode, headers, data) = try handler(request, bodyData)
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data
    }
}

private final class MockHandlerRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: MockURLProtocol.Handler] = [:]

    func set(_ handler: @escaping MockURLProtocol.Handler, forHost host: String) {
        lock.lock()
        handlers[host.lowercased()] = handler
        lock.unlock()
    }

    func remove(forHost host: String) {
        lock.lock()
        handlers.removeValue(forKey: host.lowercased())
        lock.unlock()
    }

    func handler(forHost host: String) -> MockURLProtocol.Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[host.lowercased()]
    }
}
