import Foundation

public enum DemoDataProvider {
    public static let swarmSessionID = "demo-swarm-ios-monitor"
    public static let approvalSessionID = "demo-stripe-billing-v2"
    public static let errorSessionID = "demo-ci-signing-debug"
    public static let completedSessionID = "demo-ws-security-audit"

    public static func sampleHealth(now: Date = Date()) -> HostHealth {
        HostHealth(
            status: "ok",
            apiVersion: "1.0",
            hostname: "workstation-m4-max.local",
            platform: "macOS 15.2 (arm64)",
            uptimeSeconds: 184_320,
            brainDir: "~/.gemini/antigravity/brain",
            brainDirExists: true,
            sessionCount: 4,
            activeSessionCount: 2,
            pendingApprovalCount: 2,
            totalInputTokens: 612_400,
            totalCacheReadTokens: 2_384_900,
            totalOutputTokens: 148_250,
            serverTime: now
        )
    }

    public static func sampleSessions(now: Date = Date()) -> [SessionSummary] {
        [
            SessionSummary(
                id: swarmSessionID,
                title: "Build Native iOS Antigravity Monitor (/swarm)",
                status: .running,
                createdAt: now.addingTimeInterval(-2_400),
                updatedAt: now.addingTimeInterval(-12),
                stepCount: 28,
                model: "gemini-2.5-pro",
                inputTokens: 284_200,
                cacheReadTokens: 1_240_500,
                outputTokens: 64_180,
                artifactCount: 3,
                taskCount: 2,
                subagentCount: 3,
                hasSwarm: true,
                lastStepPreview: "Swarm workers bridge-dev, ios-core, and ios-app are converging on v1 wire contract verification."
            ),
            SessionSummary(
                id: approvalSessionID,
                title: "Migrate Billing Webhooks to Idempotent Queue",
                status: .waiting,
                createdAt: now.addingTimeInterval(-5_400),
                updatedAt: now.addingTimeInterval(-38),
                stepCount: 16,
                model: "claude-sonnet-4-5",
                inputTokens: 142_600,
                cacheReadTokens: 580_200,
                outputTokens: 31_420,
                artifactCount: 2,
                taskCount: 1,
                subagentCount: 1,
                hasSwarm: false,
                lastStepPreview: "Waiting for remote PreToolUse approval to execute database migration dry-run."
            ),
            SessionSummary(
                id: errorSessionID,
                title: "Debug Xcode 16 Archive Provisioning Profile",
                status: .error,
                createdAt: now.addingTimeInterval(-9_600),
                updatedAt: now.addingTimeInterval(-1_120),
                stepCount: 11,
                model: "gemini-2.5-pro",
                inputTokens: 86_900,
                cacheReadTokens: 214_100,
                outputTokens: 19_850,
                artifactCount: 1,
                taskCount: 1,
                subagentCount: 0,
                hasSwarm: false,
                lastStepPreview: "xcodebuild exited with code 65: automatic signing requires development team ID."
            ),
            SessionSummary(
                id: completedSessionID,
                title: "Audit RFC 6455 WebSocket Framing & Constant-Time Auth",
                status: .completed,
                createdAt: now.addingTimeInterval(-28_800),
                updatedAt: now.addingTimeInterval(-14_200),
                stepCount: 22,
                model: "gemini-2.5-pro",
                inputTokens: 98_700,
                cacheReadTokens: 350_100,
                outputTokens: 32_800,
                artifactCount: 2,
                taskCount: 2,
                subagentCount: 2,
                hasSwarm: true,
                lastStepPreview: "All 42 loopback HTTP + WebSocket e2e tests passed with zero security findings."
            )
        ]
    }

    public static func sampleTranscript(for sessionId: String, now: Date = Date()) -> TranscriptResponse {
        switch sessionId {
        case approvalSessionID:
            let steps: [TranscriptStep] = [
                TranscriptStep(
                    stepIndex: 1,
                    source: "USER_EXPLICIT",
                    type: "USER_INPUT",
                    status: "DONE",
                    createdAt: now.addingTimeInterval(-900),
                    content: "Refactor our billing webhook processor to persist events in an idempotent inbox table before dispatching handlers."
                ),
                TranscriptStep(
                    stepIndex: 2,
                    source: "MODEL",
                    type: "PLANNER_RESPONSE",
                    status: "DONE",
                    createdAt: now.addingTimeInterval(-640),
                    model: "claude-sonnet-4-5",
                    inputTokens: 24_800,
                    cacheReadTokens: 96_400,
                    outputTokens: 3_120,
                    content: "I have implemented the `webhook_inbox` migration and updated `WebhookProcessor` to deduplicate on `(provider, event_id)` inside a serializable transaction.\n\nNext, I will run the migration dry-run against the staging schema.",
                    thinking: "Need to verify the unique composite index handles retries safely under concurrent webhook delivery without deadlocking active invoice updates.",
                    toolCalls: [
                        ToolCallItem(
                            name: "edit_file",
                            argsJson: "{\"path\":\"services/billing/webhook_processor.py\",\"target\":\"def handle_event(payload):\",\"replacement\":\"def handle_event(payload, idempotency_key):\"}"
                        )
                    ]
                ),
                TranscriptStep(
                    stepIndex: 3,
                    source: "MODEL",
                    type: "PLANNER_RESPONSE",
                    status: "RUNNING",
                    createdAt: now.addingTimeInterval(-40),
                    model: "claude-sonnet-4-5",
                    inputTokens: 18_200,
                    cacheReadTokens: 112_000,
                    outputTokens: 480,
                    content: "Requesting approval to run the staging migration dry-run command.",
                    thinking: "PreToolUse hook is configured for run_command. Pausing for explicit allow/deny from Antigravity Monitor iOS.",
                    toolCalls: [
                        ToolCallItem(
                            name: "run_command",
                            argsJson: "{\"command\":\"alembic upgrade head --sql > migration_preview.sql\",\"cwd\":\"services/billing\"}"
                        )
                    ]
                )
            ]
            return TranscriptResponse(sessionId: sessionId, totalSteps: steps.count, steps: steps)

        default:
            let steps: [TranscriptStep] = [
                TranscriptStep(
                    stepIndex: 1,
                    source: "USER_EXPLICIT",
                    type: "USER_INPUT",
                    status: "DONE",
                    createdAt: now.addingTimeInterval(-2_350),
                    content: "Build a native SwiftUI iOS companion app + zero-dependency Python bridge for monitoring Google Antigravity 2.0 sessions and approving PreToolUse hooks remotely."
                ),
                TranscriptStep(
                    stepIndex: 2,
                    source: "MODEL",
                    type: "PLANNER_RESPONSE",
                    status: "DONE",
                    createdAt: now.addingTimeInterval(-2_180),
                    model: "gemini-2.5-pro",
                    inputTokens: 32_100,
                    cacheReadTokens: 148_900,
                    outputTokens: 2_840,
                    content: "I've frozen the v1 HTTP + WebSocket wire contract and launched a 3-worker `/swarm` to build the bridge, `AntigravityCore` Swift Package, and native SwiftUI iOS app + Live Activities in parallel.\n\n### Parallel Ownership\n- **bridge-dev**: Pure Python 3.10+ stdlib HTTP/1.1 + RFC 6455 WS server & hooks\n- **ios-core**: Swift 5.10 `AntigravityCore` models, REST/WS clients, Keychain & Bonjour\n- **ios-app**: Native iOS 17+ SwiftUI views, actionable notifications & Dynamic Island",
                    thinking: "Freezing every JSON key, ISO-8601 timestamp format, pairing URI scheme, and approval state transition up front eliminates drift between Python and Swift workers.",
                    toolCalls: [
                        ToolCallItem(
                            name: "swarm",
                            argsJson: "{\"action\":\"add\",\"name\":\"bridge-dev\",\"brief\":\"Build pure Python stdlib bridge server and hooks\"}"
                        ),
                        ToolCallItem(
                            name: "swarm",
                            argsJson: "{\"action\":\"add\",\"name\":\"ios-core\",\"brief\":\"Build AntigravityCore Swift 5.10 package and XCTest suite\"}"
                        ),
                        ToolCallItem(
                            name: "swarm",
                            argsJson: "{\"action\":\"add\",\"name\":\"ios-app\",\"brief\":\"Build native iOS 17 SwiftUI app, WidgetKit and Live Activity\"}"
                        )
                    ]
                ),
                TranscriptStep(
                    stepIndex: 3,
                    source: "SYSTEM",
                    type: "SWARM_MESSAGE",
                    status: "DONE",
                    createdAt: now.addingTimeInterval(-720),
                    content: "[swarm] @bridge-dev reported 36/36 unittest cases passing including loopback WebSocket streaming and path traversal checks."
                ),
                TranscriptStep(
                    stepIndex: 4,
                    source: "MODEL",
                    type: "PLANNER_RESPONSE",
                    status: "RUNNING",
                    createdAt: now.addingTimeInterval(-15),
                    model: "gemini-2.5-pro",
                    inputTokens: 41_800,
                    cacheReadTokens: 312_400,
                    outputTokens: 3_490,
                    content: "Integrating `AntigravityCore` with `MonitorStore` and verifying that Dynamic Island Live Activities update on every `step_added` and `approval_requested` WebSocket event.\n\n```swift\nfor await event in wsClient.eventStream() {\n    handle(event)\n}\n```",
                    thinking: "Double-checking Swift 5.10 strict concurrency: AsyncStream.Continuation is Sendable while AsyncStream itself is not, so creating the stream via a nonisolated factory avoids actor boundary warnings.",
                    toolCalls: [
                        ToolCallItem(
                            name: "run_command",
                            argsJson: "{\"command\":\"swift test --package-path ios/Packages/AntigravityCore\",\"wait_ms\":10000}"
                        )
                    ]
                )
            ]
            return TranscriptResponse(sessionId: sessionId, totalSteps: steps.count, steps: steps)
        }
    }

    public static func sampleArtifacts(for sessionId: String, now: Date = Date()) -> ArtifactsResponse {
        let items: [ArtifactItem] = [
            ArtifactItem(
                name: "implementation_plan.md",
                relativePath: "implementation_plan.md",
                mimeType: "text/markdown",
                sizeBytes: 4_820,
                updatedAt: now.addingTimeInterval(-1_800),
                isImage: false
            ),
            ArtifactItem(
                name: "wire_contract_v1.md",
                relativePath: "wire_contract_v1.md",
                mimeType: "text/markdown",
                sizeBytes: 6_140,
                updatedAt: now.addingTimeInterval(-900),
                isImage: false
            ),
            ArtifactItem(
                name: "verification_report.md",
                relativePath: "verification_report.md",
                mimeType: "text/markdown",
                sizeBytes: 2_950,
                updatedAt: now.addingTimeInterval(-60),
                isImage: false
            )
        ]
        return ArtifactsResponse(sessionId: sessionId, artifacts: items)
    }

    public static func sampleArtifactContent(sessionId: String, relativePath: String) -> ArtifactContentResponse {
        let content: String
        switch relativePath {
        case "wire_contract_v1.md":
            content = """
            # Frozen v1 Wire Contract

            ## Pairing & Discovery
            - Deep Link / QR URI: `agymon://pair?url=<encoded>&token=<token>&name=<encoded>`
            - LAN Bonjour Service: `_antigravity-mon._tcp` (`local.`)
            - Authentication: `Authorization: Bearer <token>`

            ## Real-Time WebSocket Events (`/api/v1/ws`)
            - `hello` — Initial handshake payload & host telemetry
            - `session_updated` — Session metadata, status, or token deltas
            - `step_added` — Live transcript step appended to JSONL log
            - `approval_requested` / `approval_resolved` — Remote `PreToolUse` decision flow
            - `health_tick` — Periodic workstation heartbeat
            """
        case "verification_report.md":
            content = """
            # Verification Report

            | Suite | Target | Status |
            | --- | --- | --- |
            | Bridge E2E | `python -m unittest discover -s bridge/tests -v` | Passing (36 tests) |
            | Core Package | `swift test` (`AntigravityCoreTests`) | Passing (32 tests) |
            | iOS Build | `xcodebuild -scheme AntigravityMonitor` | Ready for macOS CI |

            All path-traversal guards, constant-time bearer auth checks, and ISO-8601 fractional timestamp codecs verified.
            """
        default:
            content = """
            # Native iOS Antigravity Monitor — Implementation Plan

            ## Architecture
            1. **Python Companion Bridge (`bridge/`)**: Zero-dependency `asyncio` HTTP/1.1 + RFC 6455 WebSocket server reading `~/.gemini/antigravity/brain` and serving `PreToolUse` approvals.
            2. **Swift Core Library (`AntigravityCore`)**: Strict-concurrency Swift 5.10 package providing Codable models, REST/WS clients, Keychain storage, App Group sharing, and Bonjour discovery.
            3. **Native iOS 17+ App & Extensions**: SwiftUI dashboard, actionable approval notifications, QR/Bonjour pairing, WidgetKit status cards, and Dynamic Island Live Activities.
            """
        }

        let name = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        return ArtifactContentResponse(
            name: name,
            relativePath: relativePath,
            mimeType: "text/markdown",
            content: content
        )
    }

    public static func sampleTasks(for sessionId: String, now: Date = Date()) -> SessionTasksResponse {
        SessionTasksResponse(
            sessionId: sessionId,
            tasks: [
                TaskLogItem(
                    taskId: "task-bridge-tests",
                    filename: "task-bridge-tests.log",
                    sizeBytes: 3_420,
                    updatedAt: now.addingTimeInterval(-95),
                    tail: """
                    test_auth_rejects_invalid_bearer ... ok
                    test_path_traversal_blocked ... ok
                    test_websocket_step_stream_and_ping_pong ... ok
                    test_pre_tool_use_approval_allow_flow ... ok
                    ----------------------------------------------------------------------
                    Ran 36 tests in 0.842s

                    OK
                    """
                ),
                TaskLogItem(
                    taskId: "task-swift-tests",
                    filename: "task-swift-tests.log",
                    sizeBytes: 2_180,
                    updatedAt: now.addingTimeInterval(-25),
                    tail: """
                    Test Suite 'AntigravityCoreTests' started.
                    Test Case 'BridgeModelsTests.testDecodeISO8601WithAndWithoutFractionalSeconds' passed (0.002s).
                    Test Case 'BridgeAPIClientTests.testSubmitApprovalDecision' passed (0.008s).
                    Test Case 'HostProfileStoreTests.testActiveHostFallbackOnDelete' passed (0.004s).
                    Executed 32 tests, with 0 failures in 0.114 seconds.
                    """
                )
            ],
            subagents: [
                SubagentInvocation(
                    stepIndex: 2,
                    role: "bridge-dev",
                    typeName: "swarm-worker",
                    promptPreview: "Build zero-dependency Python 3.10+ bridge server, hooks, QR renderer, and unittest suite.",
                    createdAt: now.addingTimeInterval(-2_160)
                ),
                SubagentInvocation(
                    stepIndex: 2,
                    role: "ios-core",
                    typeName: "swarm-worker",
                    promptPreview: "Build Swift 5.10 AntigravityCore package with strict concurrency, REST/WS clients, and XCTest.",
                    createdAt: now.addingTimeInterval(-2_158)
                ),
                SubagentInvocation(
                    stepIndex: 2,
                    role: "ios-app",
                    typeName: "swarm-worker",
                    promptPreview: "Build SwiftUI iOS 17+ app, actionable approval notifications, WidgetKit, and Live Activity.",
                    createdAt: now.addingTimeInterval(-2_155)
                )
            ],
            swarmEvents: [
                SwarmEventItem(
                    stepIndex: 2,
                    action: "add",
                    target: "bridge-dev",
                    summary: "Spawned worker owning bridge/ with frozen v1 wire contract.",
                    createdAt: now.addingTimeInterval(-2_160)
                ),
                SwarmEventItem(
                    stepIndex: 2,
                    action: "add",
                    target: "ios-core",
                    summary: "Spawned worker owning ios/Packages/AntigravityCore/.",
                    createdAt: now.addingTimeInterval(-2_158)
                ),
                SwarmEventItem(
                    stepIndex: 3,
                    action: "done",
                    target: "bridge-dev",
                    summary: "Completed bridge server & hooks; 36/36 e2e tests passing.",
                    createdAt: now.addingTimeInterval(-720)
                ),
                SwarmEventItem(
                    stepIndex: 4,
                    action: "handoff",
                    target: "ios-app",
                    summary: "Published verified AntigravityCore public API surface for UI integration.",
                    createdAt: now.addingTimeInterval(-120)
                )
            ]
        )
    }

    public static func sampleApprovals(now: Date = Date()) -> [ApprovalRequest] {
        [
            ApprovalRequest(
                id: "appr-demo-001",
                sessionId: approvalSessionID,
                hookEvent: "PreToolUse",
                toolName: "run_command",
                argsJson: "{\"command\":\"alembic upgrade head --sql > migration_preview.sql\",\"cwd\":\"services/billing\",\"timeout_ms\":30000}",
                summary: "Generate SQL dry-run preview for webhook_inbox database migration",
                status: .pending,
                createdAt: now.addingTimeInterval(-12),
                expiresAt: now.addingTimeInterval(43)
            ),
            ApprovalRequest(
                id: "appr-demo-002",
                sessionId: swarmSessionID,
                hookEvent: "PreToolUse",
                toolName: "write_file",
                argsJson: "{\"path\":\".agents/hooks.json\",\"overwrite\":true}",
                summary: "Register Antigravity PreToolUse and Stop companion hooks",
                status: .pending,
                createdAt: now.addingTimeInterval(-5),
                expiresAt: now.addingTimeInterval(50)
            ),
            ApprovalRequest(
                id: "appr-demo-003",
                sessionId: swarmSessionID,
                hookEvent: "PreToolUse",
                toolName: "run_command",
                argsJson: "{\"command\":\"python -m unittest discover -s bridge/tests -v\"}",
                summary: "Run companion bridge unit & WebSocket e2e test suite",
                status: .approved,
                createdAt: now.addingTimeInterval(-780),
                expiresAt: now.addingTimeInterval(-725),
                decision: .allow,
                decisionReason: "Approved from iPhone",
                decidedAt: now.addingTimeInterval(-774)
            ),
            ApprovalRequest(
                id: "appr-demo-004",
                sessionId: errorSessionID,
                hookEvent: "PreToolUse",
                toolName: "run_command",
                argsJson: "{\"command\":\"git push --force origin release/1.0\"}",
                summary: "Force push release branch to origin",
                status: .denied,
                createdAt: now.addingTimeInterval(-1_600),
                expiresAt: now.addingTimeInterval(-1_545),
                decision: .deny,
                decisionReason: "Never force push release branch",
                decidedAt: now.addingTimeInterval(-1_588)
            )
        ]
    }

    public static func sampleWidgetSnapshot(now: Date = Date()) -> WidgetStatusSnapshot {
        let health = sampleHealth(now: now)
        let primary = sampleSessions(now: now).first
        return WidgetStatusSnapshot(
            hostName: health.hostname,
            isConnected: true,
            isDemoMode: true,
            activeSessionCount: health.activeSessionCount,
            totalSessionCount: health.sessionCount,
            pendingApprovalCount: health.pendingApprovalCount,
            activeSessionId: primary?.id,
            activeSessionTitle: primary?.title,
            activeSessionStatus: primary?.status,
            activeSessionModel: primary?.model,
            activeSessionStepCount: primary?.stepCount ?? 0,
            totalTokens: health.totalTokens,
            cacheHitRate: health.cacheHitRate,
            updatedAt: now
        )
    }
}
