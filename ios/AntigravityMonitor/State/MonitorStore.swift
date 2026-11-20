import AntigravityCore
import Foundation
import Observation
import WidgetKit

#if canImport(ActivityKit)
import ActivityKit
#endif

@Observable
@MainActor
public final class MonitorStore {
    public enum AppTab: Hashable, Sendable {
        case sessions
        case approvals
        case telemetry
        case settings
    }

    // MARK: - Navigation & Presentation

    public var selectedTab: AppTab = .sessions
    public var selectedSessionId: String?
    public var isPresentingPairingSheet: Bool = false

    // MARK: - Hosts & Mode

    public private(set) var hosts: [HostProfile] = []
    public private(set) var activeHost: HostProfile?
    public private(set) var isDemoMode: Bool

    public var liveActivitiesEnabled: Bool {
        didSet {
            UserDefaults.standard.set(liveActivitiesEnabled, forKey: Keys.liveActivitiesEnabled)
            if !liveActivitiesEnabled {
                stopLiveActivity()
            } else if let primary = preferredLiveActivitySession {
                syncLiveActivity(with: primary)
            }
        }
    }

    // MARK: - Live State

    public private(set) var connectionState: ConnectionState = .disconnected
    public private(set) var health: HostHealth?
    public private(set) var sessions: [SessionSummary] = []
    public private(set) var approvals: [ApprovalRequest] = []
    public private(set) var recentHookEvents: [BridgeEvent] = []

    // MARK: - Session Detail Cache

    public private(set) var transcriptsBySession: [String: [TranscriptStep]] = [:]
    public private(set) var totalStepsBySession: [String: Int] = [:]
    public private(set) var artifactsBySession: [String: [ArtifactItem]] = [:]
    public private(set) var tasksBySession: [String: SessionTasksResponse] = [:]

    // MARK: - Loading & Status

    public private(set) var isRefreshing: Bool = false
    public private(set) var loadingDetailSessionIds: Set<String> = []
    public private(set) var resolvingApprovalIds: Set<String> = []
    public private(set) var lastError: String?
    public private(set) var lastRefreshedAt: Date?
    public private(set) var activeLiveActivitySessionId: String?

    public let notifications: NotificationManager

    // MARK: - Private Infrastructure

    @ObservationIgnored
    private let hostStore: HostProfileStore

    @ObservationIgnored
    private var apiClient: BridgeAPIClient?

    @ObservationIgnored
    private var wsClient: BridgeWebSocketClient?

    @ObservationIgnored
    private var wsEventTask: Task<Void, Never>?

    @ObservationIgnored
    private var wsStateTask: Task<Void, Never>?

    @ObservationIgnored
    private var hasStarted = false

    @ObservationIgnored
    private var lastKnownSessionStatus: [String: SessionStatus] = [:]

    private enum Keys {
        static let liveActivitiesEnabled = "agymon.liveActivities.enabled"
    }

    // MARK: - Init

    public init(
        hostStore: HostProfileStore? = nil,
        notifications: NotificationManager? = nil
    ) {
        let resolvedHostStore = hostStore ?? HostProfileStore(
            appGroupIdentifier: HostProfileStore.defaultAppGroupIdentifier
        )
        let resolvedNotifications = notifications ?? NotificationManager()
        self.hostStore = resolvedHostStore
        self.notifications = resolvedNotifications

        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.liveActivitiesEnabled) == nil {
            self.liveActivitiesEnabled = true
        } else {
            self.liveActivitiesEnabled = defaults.bool(forKey: Keys.liveActivitiesEnabled)
        }

        let loadedHosts = resolvedHostStore.loadProfiles()
        let active = resolvedHostStore.activeProfile()
        self.hosts = loadedHosts
        self.activeHost = active
        // Demo Mode defaults ON strictly when no real host has been paired yet.
        self.isDemoMode = (active == nil)
    }

    // MARK: - Computed Helpers

    public var hasPairedHosts: Bool {
        !hosts.isEmpty
    }

    public var pendingApprovals: [ApprovalRequest] {
        approvals
            .filter { $0.isPending && $0.expiresAt > Date() }
            .sorted { $0.expiresAt < $1.expiresAt }
    }

    public var resolvedApprovals: [ApprovalRequest] {
        approvals
            .filter { !$0.isPending || $0.expiresAt <= Date() }
            .sorted { ($0.decidedAt ?? $0.expiresAt) > ($1.decidedAt ?? $1.expiresAt) }
    }

    public var pendingApprovalCount: Int {
        pendingApprovals.count
    }

    public var activeSessionCount: Int {
        sessions.filter(\.isActive).count
    }

    public var statusDisplayText: String {
        if isDemoMode {
            return "Demo Mode"
        }
        let hostLabel = activeHost?.name ?? "Bridge"
        switch connectionState {
        case .connected:
            return hostLabel
        case .connecting:
            return "Connecting..."
        case .reconnecting(let attempt):
            return "Retry #\(attempt)"
        case .failed:
            return "Offline"
        case .disconnected:
            return activeHost == nil ? "Pair Host" : "Disconnected"
        }
    }

    private var preferredLiveActivitySession: SessionSummary? {
        if let pinnedId = activeLiveActivitySessionId,
           let pinned = sessions.first(where: { $0.id == pinnedId }) {
            return pinned
        }
        return sessions.first(where: { $0.status == .running })
            ?? sessions.first(where: { $0.status == .waiting })
    }

    // MARK: - Lifecycle

    public func start() {
        guard !hasStarted else { return }
        hasStarted = true

        wireNotificationCallbacks()

        Task {
            await notifications.refreshAuthorizationStatus()
            if isDemoMode {
                loadDemoData()
            } else if let host = activeHost {
                await activateLiveHost(host)
            } else {
                loadDemoData()
            }
        }
    }

    public func clearError() {
        lastError = nil
    }

    // MARK: - Deep Links

    public func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == PairingURI.scheme else { return }

        let action = (url.host ?? "").lowercased()
        switch action {
        case PairingURI.pairHost:
            do {
                let payload = try PairingURI.parse(url)
                Task {
                    do {
                        try await pairHost(
                            baseURL: payload.baseURL,
                            token: payload.token,
                            name: payload.name
                        )
                        isPresentingPairingSheet = false
                    } catch {
                        lastError = "Failed to pair host '\(payload.name)': \(error.localizedDescription)"
                    }
                }
            } catch {
                lastError = error.localizedDescription
            }

        case "approvals":
            selectedTab = .approvals

        case "session":
            let sessionId = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !sessionId.isEmpty {
                selectedTab = .sessions
                selectedSessionId = sessionId
            }

        default:
            break
        }
    }

    // MARK: - Host & Mode Management

    public func testConnection(baseURL: URL, token: String) async throws -> HostHealth {
        let client = BridgeAPIClient(baseURL: baseURL, token: token)
        _ = try await client.ping()
        return try await client.fetchHealth()
    }

    public func pairHost(baseURL: URL, token: String, name: String) async throws {
        let normalizedURL = try PairingURI.normalizeBaseURL(baseURL.absoluteString)
        let healthResult = try await testConnection(baseURL: normalizedURL, token: token)
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? healthResult.hostname
            : name.trimmingCharacters(in: .whitespacesAndNewlines)

        let saved = try hostStore.upsertHost(
            name: resolvedName,
            baseURL: normalizedURL,
            token: token,
            makeActive: true
        )
        hostStore.updateLastConnected(for: saved.id)
        hosts = hostStore.loadProfiles()
        activeHost = saved
        isDemoMode = false
        health = healthResult

        clearSessionCaches()
        await activateLiveHost(saved)
    }

    public func selectHost(_ host: HostProfile) async {
        hostStore.setActiveHost(id: host.id)
        hosts = hostStore.loadProfiles()
        activeHost = host
        isDemoMode = false
        clearSessionCaches()
        await activateLiveHost(host)
    }

    public func removeHost(_ host: HostProfile) async {
        do {
            try hostStore.removeHost(id: host.id)
            hosts = hostStore.loadProfiles()
            let nextActive = hostStore.activeProfile()
            activeHost = nextActive

            if let nextActive {
                if !isDemoMode {
                    clearSessionCaches()
                    await activateLiveHost(nextActive)
                }
            } else {
                await disconnectWebSocket()
                apiClient = nil
                isDemoMode = true
                loadDemoData()
            }
        } catch {
            lastError = "Failed to remove workstation: \(error.localizedDescription)"
        }
    }

    public func setDemoMode(_ enabled: Bool) async {
        if enabled {
            isDemoMode = true
            await disconnectWebSocket()
            apiClient = nil
            clearSessionCaches()
            loadDemoData()
        } else if let host = activeHost ?? hosts.first {
            isDemoMode = false
            activeHost = host
            hostStore.setActiveHost(id: host.id)
            clearSessionCaches()
            await activateLiveHost(host)
        } else {
            isDemoMode = true
            isPresentingPairingSheet = true
        }
    }

    // MARK: - REST Fetching

    public func refreshAll() async {
        if isDemoMode {
            loadDemoData()
            return
        }

        guard let client = apiClient else {
            if let host = activeHost {
                await activateLiveHost(host)
            }
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            async let healthTask = client.fetchHealth()
            async let sessionsTask = client.fetchSessions(limit: 50)
            async let approvalsTask = client.fetchApprovals()

            let (fetchedHealth, fetchedSessions, fetchedApprovals) = try await (
                healthTask,
                sessionsTask,
                approvalsTask
            )

            health = fetchedHealth
            sessions = fetchedSessions.sessions.sorted { $0.updatedAt > $1.updatedAt }
            approvals = fetchedApprovals.approvals
            lastRefreshedAt = Date()
            lastError = nil

            for session in sessions {
                lastKnownSessionStatus[session.id] = session.status
            }

            if let activeId = activeHost?.id {
                hostStore.updateLastConnected(for: activeId)
            }

            syncExternalSurfaces()
        } catch is CancellationError {
            // Ignore cancellation during refresh.
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func loadSessionDetails(sessionId: String, fullTranscript: Bool = false) async {
        loadingDetailSessionIds.insert(sessionId)
        defer { loadingDetailSessionIds.remove(sessionId) }

        if isDemoMode {
            let transcript = DemoDataProvider.sampleTranscript(for: sessionId)
            transcriptsBySession[sessionId] = transcript.steps
            totalStepsBySession[sessionId] = transcript.totalSteps
            artifactsBySession[sessionId] = DemoDataProvider.sampleArtifacts(for: sessionId).artifacts
            tasksBySession[sessionId] = DemoDataProvider.sampleTasks(for: sessionId)
            return
        }

        async let transcriptLoad: () = loadTranscript(sessionId: sessionId, full: fullTranscript)
        async let artifactsLoad: () = loadArtifacts(sessionId: sessionId)
        async let tasksLoad: () = loadTasks(sessionId: sessionId)
        _ = await (transcriptLoad, artifactsLoad, tasksLoad)
    }

    public func loadTranscript(sessionId: String, full: Bool = false) async {
        if isDemoMode {
            let transcript = DemoDataProvider.sampleTranscript(for: sessionId)
            transcriptsBySession[sessionId] = transcript.steps
            totalStepsBySession[sessionId] = transcript.totalSteps
            return
        }

        guard let client = apiClient else { return }
        do {
            let response = try await client.fetchTranscript(
                sessionId: sessionId,
                sinceStep: 0,
                limit: 250,
                full: full
            )
            transcriptsBySession[sessionId] = response.steps
            totalStepsBySession[sessionId] = response.totalSteps
        } catch is CancellationError {
            // Ignore view task cancellation.
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func loadArtifacts(sessionId: String) async {
        if isDemoMode {
            artifactsBySession[sessionId] = DemoDataProvider.sampleArtifacts(for: sessionId).artifacts
            return
        }

        guard let client = apiClient else { return }
        do {
            let response = try await client.fetchArtifacts(sessionId: sessionId)
            artifactsBySession[sessionId] = response.artifacts
        } catch is CancellationError {
            // Ignore view task cancellation.
        } catch {
            // Non-fatal: keep existing cached artifacts if available.
        }
    }

    public func loadTasks(sessionId: String) async {
        if isDemoMode {
            tasksBySession[sessionId] = DemoDataProvider.sampleTasks(for: sessionId)
            return
        }

        guard let client = apiClient else { return }
        do {
            let response = try await client.fetchTasks(sessionId: sessionId)
            tasksBySession[sessionId] = response
        } catch is CancellationError {
            // Ignore view task cancellation.
        } catch {
            // Non-fatal: keep existing cached tasks if available.
        }
    }

    public func fetchArtifactText(sessionId: String, relativePath: String) async throws -> ArtifactContentResponse {
        if isDemoMode {
            return DemoDataProvider.sampleArtifactContent(sessionId: sessionId, relativePath: relativePath)
        }
        guard let client = apiClient else {
            throw BridgeAPIError.networkError("No active bridge connection.")
        }
        return try await client.fetchArtifactContent(sessionId: sessionId, relativePath: relativePath)
    }

    public func fetchArtifactBinary(sessionId: String, relativePath: String) async -> Data? {
        guard !isDemoMode, let client = apiClient else { return nil }
        return try? await client.fetchArtifactBinary(sessionId: sessionId, relativePath: relativePath)
    }

    public func fetchMediaData(urlPath: String) async -> Data? {
        guard !isDemoMode, let client = apiClient else { return nil }
        return try? await client.fetchMediaData(urlPath: urlPath)
    }

    // MARK: - Approvals

    public func submitApproval(
        approvalId: String,
        decision: ApprovalDecision,
        reason: String? = nil
    ) async {
        if isDemoMode {
            resolveDemoApproval(approvalId: approvalId, decision: decision, reason: reason)
            return
        }

        guard let client = apiClient else { return }
        resolvingApprovalIds.insert(approvalId)
        defer { resolvingApprovalIds.remove(approvalId) }

        do {
            let updated = try await client.submitApprovalDecision(
                approvalId: approvalId,
                decision: decision,
                reason: reason
            )
            upsertApproval(updated)
            notifications.removeApprovalNotification(approvalId: approvalId)
            syncExternalSurfaces()
        } catch {
            lastError = "Approval submission failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Live Activity Control

    public func toggleLiveActivity(for session: SessionSummary) {
        if activeLiveActivitySessionId == session.id {
            stopLiveActivity()
        } else {
            activeLiveActivitySessionId = session.id
            syncLiveActivity(with: session, forceStart: true)
        }
    }

    public func stopLiveActivity() {
        activeLiveActivitySessionId = nil
        #if canImport(ActivityKit)
        Task {
            for activity in Activity<AntigravityActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        #endif
    }

    // MARK: - Private Live Connection & Event Processing

    private func activateLiveHost(_ host: HostProfile) async {
        await disconnectWebSocket()

        let token: String
        do {
            token = (try hostStore.token(for: host.id)) ?? ""
        } catch {
            lastError = "Could not load Keychain token for \(host.name): \(error.localizedDescription)"
            connectionState = .failed("Missing Keychain token")
            return
        }

        let client = BridgeAPIClient(baseURL: host.baseURL, token: token)
        self.apiClient = client

        await refreshAll()
        await connectWebSocket(baseURL: host.baseURL, token: token)
    }

    private func connectWebSocket(baseURL: URL, token: String) async {
        let socket = BridgeWebSocketClient(baseURL: baseURL, token: token)
        self.wsClient = socket

        wsStateTask = Task { @MainActor [weak self] in
            for await newState in socket.stateStream() {
                guard let self, !Task.isCancelled else { break }
                self.connectionState = newState
                if newState.isConnected, let activeId = self.activeHost?.id {
                    self.hostStore.updateLastConnected(for: activeId)
                }
                self.syncWidgetSnapshot()
            }
        }

        wsEventTask = Task { @MainActor [weak self] in
            for await event in socket.eventStream() {
                guard let self, !Task.isCancelled else { break }
                self.handleWebSocketEvent(event)
            }
        }

        await socket.connect()
    }

    private func disconnectWebSocket() async {
        wsEventTask?.cancel()
        wsEventTask = nil
        wsStateTask?.cancel()
        wsStateTask = nil

        if let existing = wsClient {
            await existing.disconnect()
            wsClient = nil
        }
        connectionState = .disconnected
    }

    private func handleWebSocketEvent(_ event: BridgeEvent) {
        switch event.type {
        case .hello:
            if let incomingHealth = event.health {
                health = incomingHealth
                lastRefreshedAt = Date()
            }
            if sessions.isEmpty {
                Task { await refreshAll() }
            }

        case .healthTick:
            if let incomingHealth = event.health {
                health = incomingHealth
                lastRefreshedAt = Date()
                syncExternalSurfaces()
            }

        case .sessionUpdated:
            if let updated = event.session {
                let previousStatus = lastKnownSessionStatus[updated.id]
                lastKnownSessionStatus[updated.id] = updated.status
                upsertSession(updated)

                if previousStatus != .error && updated.status == .error {
                    notifications.scheduleErrorNotification(
                        sessionId: updated.id,
                        title: updated.title,
                        message: updated.lastStepPreview ?? "Session entered an error state."
                    )
                } else if let previousStatus, previousStatus.isActive && updated.status == .completed {
                    notifications.scheduleSessionCompletedNotification(
                        sessionId: updated.id,
                        title: updated.title,
                        detail: updated.lastStepPreview
                    )
                }
                syncExternalSurfaces()
            }

        case .stepAdded:
            if let step = event.step, let sessionId = event.sessionId {
                var current = transcriptsBySession[sessionId] ?? []
                if let idx = current.firstIndex(where: { $0.stepIndex == step.stepIndex }) {
                    current[idx] = step
                } else {
                    current.append(step)
                    current.sort { $0.stepIndex < $1.stepIndex }
                }
                transcriptsBySession[sessionId] = current
                totalStepsBySession[sessionId] = max(totalStepsBySession[sessionId] ?? 0, current.count)

                if let existingSession = sessions.first(where: { $0.id == sessionId }),
                   activeLiveActivitySessionId == sessionId {
                    syncLiveActivity(with: existingSession)
                }
            }

        case .approvalRequested:
            if let approval = event.approval {
                upsertApproval(approval)
                notifications.scheduleApprovalNotification(
                    approvalId: approval.id,
                    toolName: approval.toolName,
                    summary: approval.summary,
                    sessionId: approval.sessionId
                )
                syncExternalSurfaces()
            }

        case .approvalResolved:
            if let approval = event.approval {
                upsertApproval(approval)
                notifications.removeApprovalNotification(approvalId: approval.id)
                syncExternalSurfaces()
            }

        case .hookEvent:
            recentHookEvents.insert(event, at: 0)
            if recentHookEvents.count > 40 {
                recentHookEvents.removeLast(recentHookEvents.count - 40)
            }
            if event.hookEventName?.lowercased() == "stop", let sid = event.sessionId {
                let title = sessions.first(where: { $0.id == sid })?.title ?? "Antigravity Session"
                notifications.scheduleSessionCompletedNotification(
                    sessionId: sid,
                    title: title,
                    detail: event.message
                )
            }

        case .pong, .unknown:
            break
        }
    }

    // MARK: - Demo Data & State Helpers

    private func loadDemoData() {
        let now = Date()
        health = DemoDataProvider.sampleHealth(now: now)
        sessions = DemoDataProvider.sampleSessions(now: now)
        approvals = DemoDataProvider.sampleApprovals(now: now)
        connectionState = .connected
        lastRefreshedAt = now
        lastError = nil
        recentHookEvents = [
            BridgeEvent(
                type: .hookEvent,
                timestamp: now.addingTimeInterval(-14),
                sessionId: DemoDataProvider.approvalSessionID,
                hookEventName: "PreToolUse",
                message: "Waiting for approval on run_command (alembic upgrade head --sql)"
            ),
            BridgeEvent(
                type: .hookEvent,
                timestamp: now.addingTimeInterval(-95),
                sessionId: DemoDataProvider.swarmSessionID,
                hookEventName: "PostToolUse",
                message: "Completed unit test run with 0 failures"
            ),
            BridgeEvent(
                type: .hookEvent,
                timestamp: now.addingTimeInterval(-240),
                sessionId: DemoDataProvider.completedSessionID,
                hookEventName: "Stop",
                message: "Turn completed cleanly"
            )
        ]

        syncExternalSurfaces()
    }

    private func resolveDemoApproval(
        approvalId: String,
        decision: ApprovalDecision,
        reason: String?
    ) {
        guard let index = approvals.firstIndex(where: { $0.id == approvalId }) else { return }
        let existing = approvals[index]
        let updated = ApprovalRequest(
            id: existing.id,
            sessionId: existing.sessionId,
            hookEvent: existing.hookEvent,
            toolName: existing.toolName,
            argsJson: existing.argsJson,
            summary: existing.summary,
            status: decision == .allow ? .approved : .denied,
            createdAt: existing.createdAt,
            expiresAt: existing.expiresAt,
            decision: decision,
            decisionReason: reason ?? (decision == .allow ? "Approved in Demo Mode" : "Denied in Demo Mode"),
            decidedAt: Date()
        )
        approvals[index] = updated
        notifications.removeApprovalNotification(approvalId: approvalId)
        syncExternalSurfaces()
    }

    private func upsertSession(_ session: SessionSummary) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
    }

    private func upsertApproval(_ approval: ApprovalRequest) {
        if let index = approvals.firstIndex(where: { $0.id == approval.id }) {
            approvals[index] = approval
        } else {
            approvals.insert(approval, at: 0)
        }
    }

    private func clearSessionCaches() {
        transcriptsBySession.removeAll()
        totalStepsBySession.removeAll()
        artifactsBySession.removeAll()
        tasksBySession.removeAll()
        recentHookEvents.removeAll()
        lastKnownSessionStatus.removeAll()
    }

    private func wireNotificationCallbacks() {
        notifications.onApprovalAction = { [weak self] approvalId, allow in
            guard let self else { return }
            Task {
                await self.submitApproval(
                    approvalId: approvalId,
                    decision: allow ? .allow : .deny,
                    reason: allow ? "Approved via notification" : "Denied via notification"
                )
            }
        }

        notifications.onSelectRoute = { [weak self] approvalId, sessionId in
            guard let self else { return }
            if approvalId != nil {
                self.selectedTab = .approvals
            } else if let sessionId, !sessionId.isEmpty {
                self.selectedTab = .sessions
                self.selectedSessionId = sessionId
            }
        }
    }

    // MARK: - WidgetKit & ActivityKit Synchronization

    private func syncExternalSurfaces() {
        notifications.updateBadgeCount(pendingApprovalCount)
        syncWidgetSnapshot()

        if liveActivitiesEnabled, let targetSession = preferredLiveActivitySession {
            if activeLiveActivitySessionId != nil || targetSession.status == .running {
                syncLiveActivity(with: targetSession, forceStart: activeLiveActivitySessionId != nil)
            }
        }
    }

    private func syncWidgetSnapshot() {
        let hostName = isDemoMode
            ? (health?.hostname ?? "Demo Workstation")
            : (activeHost?.name ?? health?.hostname ?? "Workstation")

        let topSnippets = sessions.prefix(3).map { session in
            WidgetSessionSnippet(
                id: session.id,
                title: session.title,
                status: session.status.rawValue,
                model: session.model ?? "Antigravity",
                stepCount: session.stepCount,
                updatedAt: session.updatedAt
            )
        }

        let inputTokens = health?.totalInputTokens ?? sessions.reduce(0) { $0 + $1.inputTokens }
        let cacheTokens = health?.totalCacheReadTokens ?? sessions.reduce(0) { $0 + $1.cacheReadTokens }
        let outputTokens = health?.totalOutputTokens ?? sessions.reduce(0) { $0 + $1.outputTokens }

        let richSnapshot = WidgetSnapshot(
            hostName: hostName,
            isConnected: isDemoMode || connectionState.isConnected,
            isDemoMode: isDemoMode,
            activeSessionCount: activeSessionCount,
            totalSessionCount: sessions.count,
            pendingApprovalCount: pendingApprovalCount,
            totalInputTokens: inputTokens,
            totalCacheReadTokens: cacheTokens,
            totalOutputTokens: outputTokens,
            topSessions: topSnippets,
            updatedAt: Date()
        )
        WidgetSnapshot.save(richSnapshot)

        let primary = sessions.first
        let coreSnapshot = WidgetStatusSnapshot(
            hostName: hostName,
            isConnected: isDemoMode || connectionState.isConnected,
            isDemoMode: isDemoMode,
            activeSessionCount: activeSessionCount,
            totalSessionCount: sessions.count,
            pendingApprovalCount: pendingApprovalCount,
            activeSessionId: primary?.id,
            activeSessionTitle: primary?.title,
            activeSessionStatus: primary?.status,
            activeSessionModel: primary?.model,
            activeSessionStepCount: primary?.stepCount ?? 0,
            totalTokens: inputTokens + cacheTokens + outputTokens,
            cacheHitRate: TokenFormatter.cacheHitRate(inputTokens: inputTokens, cacheReadTokens: cacheTokens),
            updatedAt: Date()
        )
        hostStore.saveWidgetSnapshot(coreSnapshot)

        WidgetCenter.shared.reloadAllTimelines()
    }

    private func syncLiveActivity(with session: SessionSummary, forceStart: Bool = false) {
        #if canImport(ActivityKit)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let hostName = isDemoMode
            ? (health?.hostname ?? "Demo Workstation")
            : (activeHost?.name ?? health?.hostname ?? "Workstation")

        let contentState = AntigravityActivityAttributes.ContentState(
            title: session.title,
            status: session.status.rawValue,
            model: session.model ?? "Antigravity",
            stepCount: session.stepCount,
            pendingApprovals: pendingApprovalCount,
            totalTokens: session.totalTokens,
            lastPreview: session.lastStepPreview ?? "",
            updatedAt: Date()
        )
        let activityContent = ActivityContent(
            state: contentState,
            staleDate: Date().addingTimeInterval(300)
        )

        let sessionId = session.id
        if Activity<AntigravityActivityAttributes>.activities.contains(where: { $0.attributes.sessionId == sessionId }) {
            activeLiveActivitySessionId = sessionId
            Task { @MainActor in
                if let existing = Activity<AntigravityActivityAttributes>.activities.first(where: { $0.attributes.sessionId == sessionId }) {
                    await existing.update(activityContent)
                }
            }
            return
        }

        guard forceStart || liveActivitiesEnabled else { return }

        let attributes = AntigravityActivityAttributes(
            sessionId: sessionId,
            hostName: hostName,
            startedAt: session.createdAt
        )

        Task { @MainActor [weak self] in
            for activity in Activity<AntigravityActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            do {
                _ = try Activity<AntigravityActivityAttributes>.request(
                    attributes: attributes,
                    content: activityContent,
                    pushType: nil
                )
                self?.activeLiveActivitySessionId = sessionId
            } catch {
                // Live Activities can fail on unsupported devices/background state; fail quietly.
            }
        }
        #endif
    }
}
