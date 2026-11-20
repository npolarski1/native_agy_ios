import Foundation
import XCTest
import AntigravityCore

final class BridgeModelsTests: XCTestCase {
    func testISO8601DecodingSupportsPlainZFractionalAndOffset() throws {
        struct Payload: Decodable {
            let plain: Date
            let millis: Date
            let micros: Date
            let offset: Date
        }

        let json = """
        {
          "plain": "2026-11-20T20:35:00Z",
          "millis": "2026-11-20T20:35:00.250Z",
          "micros": "2026-11-20T20:35:00.250000Z",
          "offset": "2026-11-20T15:35:00-05:00"
        }
        """
        let data = Data(json.utf8)
        let decoded = try BridgeJSONDecoder.decode(Payload.self, from: data)

        XCTAssertEqual(decoded.plain.timeIntervalSince1970, decoded.offset.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.millis.timeIntervalSince1970 - decoded.plain.timeIntervalSince1970, 0.25, accuracy: 0.001)
        XCTAssertEqual(decoded.micros.timeIntervalSince1970, decoded.millis.timeIntervalSince1970, accuracy: 0.001)
    }

    func testInvalidDateStringThrowsDecodingError() {
        struct Payload: Decodable { let date: Date }
        let data = Data("{\"date\":\"not-a-date\"}".utf8)
        XCTAssertThrowsError(try BridgeJSONDecoder.decode(Payload.self, from: data))
    }

    func testDecodePingAndHealth() throws {
        let pingJSON = #"{"ok": true, "api_version": "1.0"}"#
        let ping = try BridgeJSONDecoder.decode(PingResponse.self, from: Data(pingJSON.utf8))
        XCTAssertTrue(ping.ok)
        XCTAssertEqual(ping.apiVersion, "1.0")

        let healthJSON = """
        {
          "status": "ok",
          "api_version": "1.0",
          "hostname": "dev-workstation",
          "platform": "Windows-11",
          "uptime_seconds": 90061,
          "brain_dir": "C:/Users/dev/.gemini/antigravity/brain",
          "brain_dir_exists": true,
          "session_count": 5,
          "active_session_count": 2,
          "pending_approval_count": 1,
          "total_input_tokens": 200000,
          "total_cache_read_tokens": 800000,
          "total_output_tokens": 50000,
          "server_time": "2026-11-20T20:35:00Z"
        }
        """
        let health = try BridgeJSONDecoder.decode(HostHealth.self, from: Data(healthJSON.utf8))
        XCTAssertEqual(health.hostname, "dev-workstation")
        XCTAssertEqual(health.uptimeSeconds, 90_061)
        XCTAssertEqual(health.formattedUptime, "1d 1h 1m")
        XCTAssertEqual(health.totalTokens, 1_050_000)
        XCTAssertEqual(health.cacheHitRate, 0.8, accuracy: 0.0001)
        XCTAssertEqual(health.formattedCacheHitRate, "80%")
        XCTAssertEqual(health.formattedTotalTokens, "1.05M")
    }

    func testDecodeSessionsWithUnknownStatusFallback() throws {
        let json = """
        {
          "sessions": [
            {
              "id": "sess-1",
              "title": "Active Swarm",
              "status": "running",
              "created_at": "2026-11-20T20:00:00Z",
              "updated_at": "2026-11-20T20:35:00.500Z",
              "step_count": 12,
              "model": "gemini-2.5-pro",
              "input_tokens": 10000,
              "cache_read_tokens": 40000,
              "output_tokens": 2500,
              "artifact_count": 2,
              "task_count": 1,
              "subagent_count": 3,
              "has_swarm": true,
              "last_step_preview": "All workers running"
            },
            {
              "id": "sess-2",
              "title": "Future State",
              "status": "paused_by_policy",
              "created_at": "2026-11-20T19:00:00Z",
              "updated_at": "2026-11-20T19:05:00Z",
              "step_count": 3,
              "model": null,
              "input_tokens": 0,
              "cache_read_tokens": 0,
              "output_tokens": 0,
              "artifact_count": 0,
              "task_count": 0,
              "subagent_count": 0,
              "has_swarm": false,
              "last_step_preview": null
            }
          ]
        }
        """

        let response = try BridgeJSONDecoder.decode(SessionsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.sessions.count, 2)
        XCTAssertEqual(response.sessions[0].status, .running)
        XCTAssertTrue(response.sessions[0].isActive)
        XCTAssertTrue(response.sessions[0].hasSwarm)
        XCTAssertEqual(response.sessions[0].cacheHitRate, 0.8, accuracy: 0.0001)
        XCTAssertEqual(response.sessions[1].status, .unknown)
        XCTAssertFalse(response.sessions[1].isActive)
        XCTAssertNil(response.sessions[1].model)
    }

    func testDecodeTranscriptArtifactsTasksAndApprovals() throws {
        let transcriptJSON = """
        {
          "session_id": "sess-1",
          "total_steps": 1,
          "steps": [
            {
              "step_index": 4,
              "source": "MODEL",
              "type": "PLANNER_RESPONSE",
              "status": "DONE",
              "created_at": "2026-11-20T20:35:00Z",
              "model": "gemini-2.5-pro",
              "input_tokens": 1200,
              "cache_read_tokens": 4800,
              "output_tokens": 350,
              "content": "Done!",
              "thinking": "Checked all edge cases",
              "tool_calls": [
                {"name": "run_command", "args_json": "{\\"cmd\\":\\"swift test\\"}"}
              ],
              "media": [
                {"mime_type": "image/png", "filename": "shot.png", "url_path": "/api/v1/sessions/sess-1/media/shot.png"}
              ],
              "truncated_fields": ["thinking"]
            }
          ]
        }
        """

        let transcript = try BridgeJSONDecoder.decode(TranscriptResponse.self, from: Data(transcriptJSON.utf8))
        XCTAssertEqual(transcript.sessionId, "sess-1")
        XCTAssertEqual(transcript.totalSteps, 1)
        let step = try XCTUnwrap(transcript.steps.first)
        XCTAssertEqual(step.id, 4)
        XCTAssertTrue(step.isModel)
        XCTAssertTrue(step.isTruncated)
        XCTAssertEqual(step.toolCalls.count, 1)
        XCTAssertEqual(step.toolCalls[0].name, "run_command")
        XCTAssertEqual(step.media.count, 1)
        XCTAssertTrue(step.media[0].isImage)

        let tasksJSON = """
        {
          "session_id": "sess-1",
          "tasks": [
            {"task_id": "t1", "filename": "t1.log", "size_bytes": 2048, "updated_at": "2026-11-20T20:35:00Z", "tail": "OK"}
          ],
          "subagents": [
            {"step_index": 2, "role": "ios-core", "type_name": "worker", "prompt_preview": "Build core", "created_at": "2026-11-20T20:30:00Z"}
          ],
          "swarm_events": [
            {"step_index": 2, "action": "add", "target": "ios-core", "summary": "Added worker", "created_at": "2026-11-20T20:30:00Z"}
          ]
        }
        """
        let tasks = try BridgeJSONDecoder.decode(SessionTasksResponse.self, from: Data(tasksJSON.utf8))
        XCTAssertEqual(tasks.tasks.first?.id, "t1")
        XCTAssertEqual(tasks.tasks.first?.formattedSize, "2.0 KB")
        XCTAssertEqual(tasks.subagents.first?.id, "2-ios-core")
        XCTAssertEqual(tasks.swarmEvents.first?.id, "2-add-ios-core")

        let approvalsJSON = """
        {
          "approvals": [
            {
              "id": "appr-1",
              "session_id": "sess-1",
              "hook_event": "PreToolUse",
              "tool_name": "run_command",
              "args_json": "{\\"command\\":\\"rm -rf build\\"}",
              "summary": "Clean build dir",
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
        let approvals = try BridgeJSONDecoder.decode(ApprovalsResponse.self, from: Data(approvalsJSON.utf8))
        let approval = try XCTUnwrap(approvals.approvals.first)
        XCTAssertEqual(approval.status, .pending)
        XCTAssertTrue(approval.isPending)
        XCTAssertEqual(approval.toolName, "run_command")
        XCTAssertTrue(approval.prettyArgsJson.contains("\n"))
    }

    func testDecodeBridgeEventIncludingUnknownType() throws {
        let knownJSON = """
        {
          "type": "hook_event",
          "timestamp": "2026-11-20T20:35:00Z",
          "session_id": "sess-1",
          "session": null,
          "step": null,
          "approval": null,
          "hook_event_name": "Stop",
          "message": "Turn finished",
          "health": null
        }
        """
        let event = try BridgeJSONDecoder.decode(BridgeEvent.self, from: Data(knownJSON.utf8))
        XCTAssertEqual(event.type, .hookEvent)
        XCTAssertEqual(event.hookEventName, "Stop")
        XCTAssertEqual(event.message, "Turn finished")

        let unknownJSON = """
        {
          "type": "future_event_v2",
          "timestamp": "2026-11-20T20:35:00Z"
        }
        """
        let unknownEvent = try BridgeJSONDecoder.decode(BridgeEvent.self, from: Data(unknownJSON.utf8))
        XCTAssertEqual(unknownEvent.type, .unknown)
    }

    func testTokenFormatterAndWebSocketHelpers() throws {
        XCTAssertEqual(TokenFormatter.format(0), "0")
        XCTAssertEqual(TokenFormatter.format(999), "999")
        XCTAssertEqual(TokenFormatter.format(1_500), "1.5K")
        XCTAssertEqual(TokenFormatter.format(2_450_000), "2.45M")
        XCTAssertEqual(TokenFormatter.format(1_250_000_000), "1.25B")
        XCTAssertEqual(TokenFormatter.cacheHitRate(inputTokens: 0, cacheReadTokens: 0), 0.0)
        XCTAssertEqual(TokenFormatter.formatUptime(45), "45s")
        XCTAssertEqual(TokenFormatter.formatUptime(125), "2m 5s")
        XCTAssertEqual(TokenFormatter.formatUptime(7_320), "2h 2m")

        let httpBase = try XCTUnwrap(URL(string: "http://192.168.1.50:8765"))
        let wsURL = try BridgeWebSocketClient.webSocketURL(from: httpBase, token: "sec-123")
        XCTAssertEqual(wsURL.absoluteString, "ws://192.168.1.50:8765/api/v1/ws?token=sec-123")

        let httpsBase = try XCTUnwrap(URL(string: "https://box.ts.net/bridge/"))
        let wssURL = try BridgeWebSocketClient.webSocketURL(from: httpsBase, token: "tok")
        XCTAssertEqual(wssURL.absoluteString, "wss://box.ts.net/bridge/api/v1/ws?token=tok")

        XCTAssertEqual(BridgeWebSocketClient.reconnectDelay(forAttempt: 1), 1)
        XCTAssertEqual(BridgeWebSocketClient.reconnectDelay(forAttempt: 2), 2)
        XCTAssertEqual(BridgeWebSocketClient.reconnectDelay(forAttempt: 4), 8)
        XCTAssertEqual(BridgeWebSocketClient.reconnectDelay(forAttempt: 10, maxDelay: 30), 30)
    }

    func testDemoDataProviderIsCompleteAndCoherent() {
        let health = DemoDataProvider.sampleHealth()
        let sessions = DemoDataProvider.sampleSessions()
        let approvals = DemoDataProvider.sampleApprovals()
        let snapshot = DemoDataProvider.sampleWidgetSnapshot()

        XCTAssertEqual(health.sessionCount, sessions.count)
        XCTAssertTrue(sessions.contains(where: { $0.hasSwarm && $0.status == .running }))
        XCTAssertTrue(approvals.contains(where: { $0.isPending }))
        XCTAssertEqual(snapshot.pendingApprovalCount, health.pendingApprovalCount)

        let transcript = DemoDataProvider.sampleTranscript(for: DemoDataProvider.swarmSessionID)
        XCTAssertFalse(transcript.steps.isEmpty)
        XCTAssertTrue(transcript.steps.contains(where: { !($0.thinking ?? "").isEmpty && !$0.toolCalls.isEmpty }))

        let artifacts = DemoDataProvider.sampleArtifacts(for: DemoDataProvider.swarmSessionID)
        XCTAssertFalse(artifacts.artifacts.isEmpty)
        let firstArtifact = artifacts.artifacts[0]
        let content = DemoDataProvider.sampleArtifactContent(
            sessionId: DemoDataProvider.swarmSessionID,
            relativePath: firstArtifact.relativePath
        )
        XCTAssertFalse(content.content.isEmpty)

        let tasks = DemoDataProvider.sampleTasks(for: DemoDataProvider.swarmSessionID)
        XCTAssertFalse(tasks.tasks.isEmpty)
        XCTAssertFalse(tasks.subagents.isEmpty)
        XCTAssertFalse(tasks.swarmEvents.isEmpty)
    }
}
