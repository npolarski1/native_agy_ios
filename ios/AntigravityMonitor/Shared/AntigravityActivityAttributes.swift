import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// Shared ActivityKit attributes compiled into both the main app and widget extension.
public struct AntigravityActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var title: String
        public var status: String
        public var model: String
        public var stepCount: Int
        public var pendingApprovals: Int
        public var totalTokens: Int
        public var lastPreview: String
        public var updatedAt: Date

        public init(
            title: String,
            status: String,
            model: String,
            stepCount: Int,
            pendingApprovals: Int,
            totalTokens: Int,
            lastPreview: String,
            updatedAt: Date = Date()
        ) {
            self.title = title
            self.status = status
            self.model = model
            self.stepCount = stepCount
            self.pendingApprovals = pendingApprovals
            self.totalTokens = totalTokens
            self.lastPreview = lastPreview
            self.updatedAt = updatedAt
        }
    }

    public var sessionId: String
    public var hostName: String
    public var startedAt: Date

    public init(sessionId: String, hostName: String, startedAt: Date = Date()) {
        self.sessionId = sessionId
        self.hostName = hostName
        self.startedAt = startedAt
    }
}
#endif
