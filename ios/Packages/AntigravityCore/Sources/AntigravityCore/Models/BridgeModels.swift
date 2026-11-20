import Foundation

// MARK: - ISO-8601 Date Codec & JSON Coders

public enum BridgeDateCodec {
    public static func parse(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: trimmed) {
            return date
        }

        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]
        if let date = standardFormatter.date(from: trimmed) {
            return date
        }

        let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? fractionalStyle.parse(trimmed) {
            return date
        }

        let standardStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        return try? standardStyle.parse(trimmed)
    }

    public static func format(_ date: Date, includeFractionalSeconds: Bool = false) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = includeFractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

public final class BridgeJSONDecoder: JSONDecoder, @unchecked Sendable {
    public override init() {
        super.init()
        self.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = BridgeDateCodec.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date string: \(raw)"
                )
            }
            return date
        }
    }

    public static func make() -> JSONDecoder {
        BridgeJSONDecoder()
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try BridgeJSONDecoder().decode(type, from: data)
    }
}

public final class BridgeJSONEncoder: JSONEncoder, @unchecked Sendable {
    public override init() {
        super.init()
        self.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(BridgeDateCodec.format(date))
        }
    }

    public static func make() -> JSONEncoder {
        BridgeJSONEncoder()
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try BridgeJSONEncoder().encode(value)
    }
}

// MARK: - Formatting Helpers

public enum TokenFormatter {
    public static func format(_ count: Int) -> String {
        let absCount = abs(count)
        let sign = count < 0 ? "-" : ""
        switch absCount {
        case 1_000_000_000...:
            return "\(sign)\(String(format: "%.2fB", Double(absCount) / 1_000_000_000.0))"
        case 1_000_000...:
            return "\(sign)\(String(format: "%.2fM", Double(absCount) / 1_000_000.0))"
        case 1_000...:
            return "\(sign)\(String(format: "%.1fK", Double(absCount) / 1_000.0))"
        default:
            return "\(count)"
        }
    }

    /// Computes cache hit rate in `[0.0, 1.0]` as `cacheReadTokens / (inputTokens + cacheReadTokens)`.
    public static func cacheHitRate(inputTokens: Int, cacheReadTokens: Int) -> Double {
        let safeInput = max(0, inputTokens)
        let safeCache = max(0, cacheReadTokens)
        let denominator = safeInput + safeCache
        guard denominator > 0 else { return 0.0 }
        return min(1.0, max(0.0, Double(safeCache) / Double(denominator)))
    }

    public static func formatPercentage(_ ratio: Double, decimals: Int = 0) -> String {
        let clamped = min(1.0, max(0.0, ratio)) * 100.0
        if decimals <= 0 {
            return "\(Int(clamped.rounded()))%"
        }
        return String(format: "%.\(decimals)f%%", clamped)
    }

    public static func formatBytes(_ bytes: Int) -> String {
        let safeBytes = max(0, bytes)
        switch safeBytes {
        case 1_073_741_824...:
            return String(format: "%.2f GB", Double(safeBytes) / 1_073_741_824.0)
        case 1_048_576...:
            return String(format: "%.1f MB", Double(safeBytes) / 1_048_576.0)
        case 1_024...:
            return String(format: "%.1f KB", Double(safeBytes) / 1_024.0)
        default:
            return "\(safeBytes) B"
        }
    }

    public static func formatUptime(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60

        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }

    public static func prettyPrintJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              JSONSerialization.isValidJSONObject(object),
              let prettyData = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
              ),
              let pretty = String(data: prettyData, encoding: .utf8) else {
            return raw
        }
        return pretty
    }
}

// MARK: - Health & Ping

public struct PingResponse: Codable, Hashable, Sendable {
    public let ok: Bool
    public let apiVersion: String

    public init(ok: Bool, apiVersion: String) {
        self.ok = ok
        self.apiVersion = apiVersion
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case apiVersion = "api_version"
    }
}

public struct HostHealth: Codable, Hashable, Sendable {
    public let status: String
    public let apiVersion: String
    public let hostname: String
    public let platform: String
    public let uptimeSeconds: Int
    public let brainDir: String
    public let brainDirExists: Bool
    public let sessionCount: Int
    public let activeSessionCount: Int
    public let pendingApprovalCount: Int
    public let totalInputTokens: Int
    public let totalCacheReadTokens: Int
    public let totalOutputTokens: Int
    public let serverTime: Date

    public init(
        status: String,
        apiVersion: String,
        hostname: String,
        platform: String,
        uptimeSeconds: Int,
        brainDir: String,
        brainDirExists: Bool,
        sessionCount: Int,
        activeSessionCount: Int,
        pendingApprovalCount: Int,
        totalInputTokens: Int,
        totalCacheReadTokens: Int,
        totalOutputTokens: Int,
        serverTime: Date
    ) {
        self.status = status
        self.apiVersion = apiVersion
        self.hostname = hostname
        self.platform = platform
        self.uptimeSeconds = uptimeSeconds
        self.brainDir = brainDir
        self.brainDirExists = brainDirExists
        self.sessionCount = sessionCount
        self.activeSessionCount = activeSessionCount
        self.pendingApprovalCount = pendingApprovalCount
        self.totalInputTokens = totalInputTokens
        self.totalCacheReadTokens = totalCacheReadTokens
        self.totalOutputTokens = totalOutputTokens
        self.serverTime = serverTime
    }

    enum CodingKeys: String, CodingKey {
        case status
        case apiVersion = "api_version"
        case hostname
        case platform
        case uptimeSeconds = "uptime_seconds"
        case brainDir = "brain_dir"
        case brainDirExists = "brain_dir_exists"
        case sessionCount = "session_count"
        case activeSessionCount = "active_session_count"
        case pendingApprovalCount = "pending_approval_count"
        case totalInputTokens = "total_input_tokens"
        case totalCacheReadTokens = "total_cache_read_tokens"
        case totalOutputTokens = "total_output_tokens"
        case serverTime = "server_time"
    }

    public var totalTokens: Int {
        totalInputTokens + totalCacheReadTokens + totalOutputTokens
    }

    public var cacheHitRate: Double {
        TokenFormatter.cacheHitRate(
            inputTokens: totalInputTokens,
            cacheReadTokens: totalCacheReadTokens
        )
    }

    public var formattedCacheHitRate: String {
        TokenFormatter.formatPercentage(cacheHitRate)
    }

    public var formattedTotalTokens: String {
        TokenFormatter.format(totalTokens)
    }

    public var formattedUptime: String {
        TokenFormatter.formatUptime(uptimeSeconds)
    }
}

// MARK: - Sessions

public enum SessionStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case running
    case waiting
    case idle
    case error
    case completed
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self))?.lowercased() ?? ""
        self = SessionStatus(rawValue: raw) ?? .unknown
    }

    public var isActive: Bool {
        self == .running || self == .waiting
    }

    public var displayName: String {
        switch self {
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .idle: return "Idle"
        case .error: return "Error"
        case .completed: return "Completed"
        case .unknown: return "Unknown"
        }
    }
}

public struct SessionsResponse: Codable, Hashable, Sendable {
    public let sessions: [SessionSummary]

    public init(sessions: [SessionSummary]) {
        self.sessions = sessions
    }
}

public struct SessionSummary: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let title: String
    public let status: SessionStatus
    public let createdAt: Date
    public let updatedAt: Date
    public let stepCount: Int
    public let model: String?
    public let inputTokens: Int
    public let cacheReadTokens: Int
    public let outputTokens: Int
    public let artifactCount: Int
    public let taskCount: Int
    public let subagentCount: Int
    public let hasSwarm: Bool
    public let lastStepPreview: String?

    public init(
        id: String,
        title: String,
        status: SessionStatus,
        createdAt: Date,
        updatedAt: Date,
        stepCount: Int,
        model: String? = nil,
        inputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        outputTokens: Int = 0,
        artifactCount: Int = 0,
        taskCount: Int = 0,
        subagentCount: Int = 0,
        hasSwarm: Bool = false,
        lastStepPreview: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.stepCount = stepCount
        self.model = model
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.artifactCount = artifactCount
        self.taskCount = taskCount
        self.subagentCount = subagentCount
        self.hasSwarm = hasSwarm
        self.lastStepPreview = lastStepPreview
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case stepCount = "step_count"
        case model
        case inputTokens = "input_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case outputTokens = "output_tokens"
        case artifactCount = "artifact_count"
        case taskCount = "task_count"
        case subagentCount = "subagent_count"
        case hasSwarm = "has_swarm"
        case lastStepPreview = "last_step_preview"
    }

    public var isActive: Bool {
        status.isActive
    }

    public var totalTokens: Int {
        inputTokens + cacheReadTokens + outputTokens
    }

    public var cacheHitRate: Double {
        TokenFormatter.cacheHitRate(inputTokens: inputTokens, cacheReadTokens: cacheReadTokens)
    }

    public var formattedTotalTokens: String {
        TokenFormatter.format(totalTokens)
    }

    public var formattedCacheHitRate: String {
        TokenFormatter.formatPercentage(cacheHitRate)
    }
}

// MARK: - Transcript

public struct TranscriptResponse: Codable, Hashable, Sendable {
    public let sessionId: String
    public let totalSteps: Int
    public let steps: [TranscriptStep]

    public init(sessionId: String, totalSteps: Int, steps: [TranscriptStep]) {
        self.sessionId = sessionId
        self.totalSteps = totalSteps
        self.steps = steps
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case totalSteps = "total_steps"
        case steps
    }
}

public struct ToolCallItem: Identifiable, Hashable, Codable, Sendable {
    public let name: String
    public let argsJson: String

    public var id: String {
        "\(name):\(argsJson)"
    }

    public init(name: String, argsJson: String) {
        self.name = name
        self.argsJson = argsJson
    }

    enum CodingKeys: String, CodingKey {
        case name
        case argsJson = "args_json"
    }

    public var prettyArgsJson: String {
        TokenFormatter.prettyPrintJSON(argsJson)
    }
}

public struct MediaAttachment: Identifiable, Hashable, Codable, Sendable {
    public let mimeType: String
    public let filename: String
    public let urlPath: String

    public var id: String {
        urlPath
    }

    public init(mimeType: String, filename: String, urlPath: String) {
        self.mimeType = mimeType
        self.filename = filename
        self.urlPath = urlPath
    }

    enum CodingKeys: String, CodingKey {
        case mimeType = "mime_type"
        case filename
        case urlPath = "url_path"
    }

    public var isImage: Bool {
        mimeType.lowercased().hasPrefix("image/")
    }
}

public struct TranscriptStep: Identifiable, Hashable, Codable, Sendable {
    public var id: Int { stepIndex }

    public let stepIndex: Int
    public let source: String
    public let type: String
    public let status: String
    public let createdAt: Date
    public let model: String?
    public let inputTokens: Int?
    public let cacheReadTokens: Int?
    public let outputTokens: Int?
    public let content: String?
    public let thinking: String?
    public let toolCalls: [ToolCallItem]
    public let media: [MediaAttachment]
    public let truncatedFields: [String]

    public init(
        stepIndex: Int,
        source: String,
        type: String,
        status: String,
        createdAt: Date,
        model: String? = nil,
        inputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        outputTokens: Int? = nil,
        content: String? = nil,
        thinking: String? = nil,
        toolCalls: [ToolCallItem] = [],
        media: [MediaAttachment] = [],
        truncatedFields: [String] = []
    ) {
        self.stepIndex = stepIndex
        self.source = source
        self.type = type
        self.status = status
        self.createdAt = createdAt
        self.model = model
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.content = content
        self.thinking = thinking
        self.toolCalls = toolCalls
        self.media = media
        self.truncatedFields = truncatedFields
    }

    enum CodingKeys: String, CodingKey {
        case stepIndex = "step_index"
        case source
        case type
        case status
        case createdAt = "created_at"
        case model
        case inputTokens = "input_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case outputTokens = "output_tokens"
        case content
        case thinking
        case toolCalls = "tool_calls"
        case media
        case truncatedFields = "truncated_fields"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.stepIndex = try container.decode(Int.self, forKey: .stepIndex)
        self.source = try container.decode(String.self, forKey: .source)
        self.type = try container.decode(String.self, forKey: .type)
        self.status = try container.decode(String.self, forKey: .status)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
        self.cacheReadTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens)
        self.outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
        self.content = try container.decodeIfPresent(String.self, forKey: .content)
        self.thinking = try container.decodeIfPresent(String.self, forKey: .thinking)
        self.toolCalls = try container.decodeIfPresent([ToolCallItem].self, forKey: .toolCalls) ?? []
        self.media = try container.decodeIfPresent([MediaAttachment].self, forKey: .media) ?? []
        self.truncatedFields = try container.decodeIfPresent([String].self, forKey: .truncatedFields) ?? []
    }

    public var isUser: Bool {
        source.uppercased().contains("USER") || type.uppercased() == "USER_INPUT"
    }

    public var isModel: Bool {
        source.uppercased() == "MODEL" || type.uppercased() == "PLANNER_RESPONSE"
    }

    public var isSystem: Bool {
        source.uppercased() == "SYSTEM"
    }

    public var isTruncated: Bool {
        !truncatedFields.isEmpty
    }

    public var totalTokens: Int {
        (inputTokens ?? 0) + (cacheReadTokens ?? 0) + (outputTokens ?? 0)
    }
}

// MARK: - Artifacts

public struct ArtifactsResponse: Codable, Hashable, Sendable {
    public let sessionId: String
    public let artifacts: [ArtifactItem]

    public init(sessionId: String, artifacts: [ArtifactItem]) {
        self.sessionId = sessionId
        self.artifacts = artifacts
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case artifacts
    }
}

public struct ArtifactItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String { relativePath }

    public let name: String
    public let relativePath: String
    public let mimeType: String
    public let sizeBytes: Int
    public let updatedAt: Date
    public let isImage: Bool

    public init(
        name: String,
        relativePath: String,
        mimeType: String,
        sizeBytes: Int,
        updatedAt: Date,
        isImage: Bool
    ) {
        self.name = name
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.updatedAt = updatedAt
        self.isImage = isImage
    }

    enum CodingKeys: String, CodingKey {
        case name
        case relativePath = "relative_path"
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case updatedAt = "updated_at"
        case isImage = "is_image"
    }

    public var formattedSize: String {
        TokenFormatter.formatBytes(sizeBytes)
    }

    public var isMarkdown: Bool {
        let lowerName = name.lowercased()
        let lowerMime = mimeType.lowercased()
        return lowerMime.contains("markdown") || lowerName.hasSuffix(".md") || lowerName.hasSuffix(".markdown")
    }
}

public struct ArtifactContentResponse: Codable, Hashable, Sendable {
    public let name: String
    public let relativePath: String
    public let mimeType: String
    public let content: String

    public init(name: String, relativePath: String, mimeType: String, content: String) {
        self.name = name
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.content = content
    }

    enum CodingKeys: String, CodingKey {
        case name
        case relativePath = "relative_path"
        case mimeType = "mime_type"
        case content
    }
}

// MARK: - Tasks, Subagents & Swarm Events

public struct TaskLogItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String { taskId }

    public let taskId: String
    public let filename: String
    public let sizeBytes: Int
    public let updatedAt: Date
    public let tail: String

    public init(
        taskId: String,
        filename: String,
        sizeBytes: Int,
        updatedAt: Date,
        tail: String
    ) {
        self.taskId = taskId
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.updatedAt = updatedAt
        self.tail = tail
    }

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case filename
        case sizeBytes = "size_bytes"
        case updatedAt = "updated_at"
        case tail
    }

    public var formattedSize: String {
        TokenFormatter.formatBytes(sizeBytes)
    }
}

public struct SubagentInvocation: Identifiable, Hashable, Codable, Sendable {
    public var id: String { "\(stepIndex)-\(role)" }

    public let stepIndex: Int
    public let role: String
    public let typeName: String
    public let promptPreview: String
    public let createdAt: Date

    public init(
        stepIndex: Int,
        role: String,
        typeName: String,
        promptPreview: String,
        createdAt: Date
    ) {
        self.stepIndex = stepIndex
        self.role = role
        self.typeName = typeName
        self.promptPreview = promptPreview
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case stepIndex = "step_index"
        case role
        case typeName = "type_name"
        case promptPreview = "prompt_preview"
        case createdAt = "created_at"
    }
}

public struct SwarmEventItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String { "\(stepIndex)-\(action)-\(target ?? "")" }

    public let stepIndex: Int
    public let action: String
    public let target: String?
    public let summary: String
    public let createdAt: Date

    public init(
        stepIndex: Int,
        action: String,
        target: String? = nil,
        summary: String,
        createdAt: Date
    ) {
        self.stepIndex = stepIndex
        self.action = action
        self.target = target
        self.summary = summary
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case stepIndex = "step_index"
        case action
        case target
        case summary
        case createdAt = "created_at"
    }
}

public struct SessionTasksResponse: Codable, Hashable, Sendable {
    public let sessionId: String
    public let tasks: [TaskLogItem]
    public let subagents: [SubagentInvocation]
    public let swarmEvents: [SwarmEventItem]

    public init(
        sessionId: String,
        tasks: [TaskLogItem],
        subagents: [SubagentInvocation],
        swarmEvents: [SwarmEventItem]
    ) {
        self.sessionId = sessionId
        self.tasks = tasks
        self.subagents = subagents
        self.swarmEvents = swarmEvents
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case tasks
        case subagents
        case swarmEvents = "swarm_events"
    }
}

// MARK: - Approvals

public enum ApprovalStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case pending
    case approved
    case denied
    case expired

    public var isPending: Bool {
        self == .pending
    }

    public var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .approved: return "Approved"
        case .denied: return "Denied"
        case .expired: return "Expired"
        }
    }
}

public enum ApprovalDecision: String, Codable, Hashable, Sendable, CaseIterable {
    case allow
    case deny

    public var displayName: String {
        switch self {
        case .allow: return "Allow"
        case .deny: return "Deny"
        }
    }
}

public struct ApprovalRequest: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let sessionId: String?
    public let hookEvent: String
    public let toolName: String
    public let argsJson: String
    public let summary: String
    public let status: ApprovalStatus
    public let createdAt: Date
    public let expiresAt: Date
    public let decision: ApprovalDecision?
    public let decisionReason: String?
    public let decidedAt: Date?

    public init(
        id: String,
        sessionId: String? = nil,
        hookEvent: String,
        toolName: String,
        argsJson: String,
        summary: String,
        status: ApprovalStatus,
        createdAt: Date,
        expiresAt: Date,
        decision: ApprovalDecision? = nil,
        decisionReason: String? = nil,
        decidedAt: Date? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.hookEvent = hookEvent
        self.toolName = toolName
        self.argsJson = argsJson
        self.summary = summary
        self.status = status
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.decision = decision
        self.decisionReason = decisionReason
        self.decidedAt = decidedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case hookEvent = "hook_event"
        case toolName = "tool_name"
        case argsJson = "args_json"
        case summary
        case status
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case decision
        case decisionReason = "decision_reason"
        case decidedAt = "decided_at"
    }

    public var isPending: Bool {
        status.isPending
    }

    public var prettyArgsJson: String {
        TokenFormatter.prettyPrintJSON(argsJson)
    }

    public func remainingSeconds(at now: Date = Date()) -> TimeInterval {
        max(0, expiresAt.timeIntervalSince(now))
    }
}

public struct ApprovalsResponse: Codable, Hashable, Sendable {
    public let approvals: [ApprovalRequest]

    public init(approvals: [ApprovalRequest]) {
        self.approvals = approvals
    }
}

public struct ApprovalDecisionPayload: Codable, Hashable, Sendable {
    public let decision: ApprovalDecision
    public let reason: String?

    public init(decision: ApprovalDecision, reason: String? = nil) {
        self.decision = decision
        self.reason = reason
    }
}

// MARK: - WebSocket Events

public enum BridgeEventType: String, Codable, Hashable, Sendable, CaseIterable {
    case hello
    case sessionUpdated = "session_updated"
    case stepAdded = "step_added"
    case approvalRequested = "approval_requested"
    case approvalResolved = "approval_resolved"
    case hookEvent = "hook_event"
    case healthTick = "health_tick"
    case pong
    case unknown

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = BridgeEventType(rawValue: raw) ?? .unknown
    }
}

public struct BridgeEvent: Codable, Hashable, Sendable {
    public let type: BridgeEventType
    public let timestamp: Date
    public let sessionId: String?
    public let session: SessionSummary?
    public let step: TranscriptStep?
    public let approval: ApprovalRequest?
    public let hookEventName: String?
    public let message: String?
    public let health: HostHealth?

    public init(
        type: BridgeEventType,
        timestamp: Date,
        sessionId: String? = nil,
        session: SessionSummary? = nil,
        step: TranscriptStep? = nil,
        approval: ApprovalRequest? = nil,
        hookEventName: String? = nil,
        message: String? = nil,
        health: HostHealth? = nil
    ) {
        self.type = type
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.session = session
        self.step = step
        self.approval = approval
        self.hookEventName = hookEventName
        self.message = message
        self.health = health
    }

    enum CodingKeys: String, CodingKey {
        case type
        case timestamp
        case sessionId = "session_id"
        case session
        case step
        case approval
        case hookEventName = "hook_event_name"
        case message
        case health
    }
}

// MARK: - Shared Widget Status Snapshot

public struct WidgetStatusSnapshot: Codable, Hashable, Sendable {
    public let hostName: String
    public let isConnected: Bool
    public let isDemoMode: Bool
    public let activeSessionCount: Int
    public let totalSessionCount: Int
    public let pendingApprovalCount: Int
    public let activeSessionId: String?
    public let activeSessionTitle: String?
    public let activeSessionStatus: SessionStatus?
    public let activeSessionModel: String?
    public let activeSessionStepCount: Int
    public let totalTokens: Int
    public let cacheHitRate: Double
    public let updatedAt: Date

    public init(
        hostName: String,
        isConnected: Bool,
        isDemoMode: Bool,
        activeSessionCount: Int,
        totalSessionCount: Int,
        pendingApprovalCount: Int,
        activeSessionId: String? = nil,
        activeSessionTitle: String? = nil,
        activeSessionStatus: SessionStatus? = nil,
        activeSessionModel: String? = nil,
        activeSessionStepCount: Int = 0,
        totalTokens: Int = 0,
        cacheHitRate: Double = 0.0,
        updatedAt: Date = Date()
    ) {
        self.hostName = hostName
        self.isConnected = isConnected
        self.isDemoMode = isDemoMode
        self.activeSessionCount = activeSessionCount
        self.totalSessionCount = totalSessionCount
        self.pendingApprovalCount = pendingApprovalCount
        self.activeSessionId = activeSessionId
        self.activeSessionTitle = activeSessionTitle
        self.activeSessionStatus = activeSessionStatus
        self.activeSessionModel = activeSessionModel
        self.activeSessionStepCount = activeSessionStepCount
        self.totalTokens = totalTokens
        self.cacheHitRate = cacheHitRate
        self.updatedAt = updatedAt
    }

    public var formattedTotalTokens: String {
        TokenFormatter.format(totalTokens)
    }

    public var formattedCacheHitRate: String {
        TokenFormatter.formatPercentage(cacheHitRate)
    }
}
