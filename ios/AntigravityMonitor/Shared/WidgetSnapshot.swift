import Foundation

/// Shared App Group storage keys and snapshot payload read by WidgetKit extensions.
public enum AntigravityAppGroup {
    public static let suiteName = "group.com.antigravity.monitor"
    public static let snapshotKey = "antigravity.widget.snapshot.v1"

    public static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }
}

public struct WidgetSessionSnippet: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var status: String
    public var model: String
    public var stepCount: Int
    public var updatedAt: Date

    public init(
        id: String,
        title: String,
        status: String,
        model: String,
        stepCount: Int,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.model = model
        self.stepCount = stepCount
        self.updatedAt = updatedAt
    }
}

public struct WidgetSnapshot: Codable, Hashable, Sendable {
    public var hostName: String
    public var isConnected: Bool
    public var isDemoMode: Bool
    public var activeSessionCount: Int
    public var totalSessionCount: Int
    public var pendingApprovalCount: Int
    public var totalInputTokens: Int
    public var totalCacheReadTokens: Int
    public var totalOutputTokens: Int
    public var topSessions: [WidgetSessionSnippet]
    public var updatedAt: Date

    public init(
        hostName: String,
        isConnected: Bool,
        isDemoMode: Bool,
        activeSessionCount: Int,
        totalSessionCount: Int,
        pendingApprovalCount: Int,
        totalInputTokens: Int,
        totalCacheReadTokens: Int,
        totalOutputTokens: Int,
        topSessions: [WidgetSessionSnippet],
        updatedAt: Date = Date()
    ) {
        self.hostName = hostName
        self.isConnected = isConnected
        self.isDemoMode = isDemoMode
        self.activeSessionCount = activeSessionCount
        self.totalSessionCount = totalSessionCount
        self.pendingApprovalCount = pendingApprovalCount
        self.totalInputTokens = totalInputTokens
        self.totalCacheReadTokens = totalCacheReadTokens
        self.totalOutputTokens = totalOutputTokens
        self.topSessions = topSessions
        self.updatedAt = updatedAt
    }

    public var totalTokens: Int {
        totalInputTokens + totalCacheReadTokens + totalOutputTokens
    }

    public static func formatCompactTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000.0)
        } else {
            return "\(count)"
        }
    }

    public static let placeholder = WidgetSnapshot(
        hostName: "Workstation",
        isConnected: true,
        isDemoMode: true,
        activeSessionCount: 2,
        totalSessionCount: 4,
        pendingApprovalCount: 1,
        totalInputTokens: 148_200,
        totalCacheReadTokens: 112_400,
        totalOutputTokens: 24_600,
        topSessions: [
            WidgetSessionSnippet(
                id: "demo-1",
                title: "Swarm: Native iOS Monitor",
                status: "running",
                model: "gemini-2.5-pro",
                stepCount: 28,
                updatedAt: Date()
            ),
            WidgetSessionSnippet(
                id: "demo-2",
                title: "Refactor Bridge WebSocket",
                status: "waiting",
                model: "claude-sonnet-4",
                stepCount: 14,
                updatedAt: Date().addingTimeInterval(-120)
            ),
            WidgetSessionSnippet(
                id: "demo-3",
                title: "CI Build Verification",
                status: "completed",
                model: "gemini-2.5-flash",
                stepCount: 9,
                updatedAt: Date().addingTimeInterval(-900)
            )
        ],
        updatedAt: Date()
    )

    public static func save(_ snapshot: WidgetSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        AntigravityAppGroup.sharedDefaults.set(data, forKey: AntigravityAppGroup.snapshotKey)
    }

    public static func load() -> WidgetSnapshot? {
        guard let data = AntigravityAppGroup.sharedDefaults.data(forKey: AntigravityAppGroup.snapshotKey) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}
