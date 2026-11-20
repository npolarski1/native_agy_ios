import AntigravityCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct SessionListView: View {
    @Environment(MonitorStore.self) private var store
    @State private var searchText = ""
    @State private var filter: SessionFilter = .all
    @State private var navigationPath: [String] = []

    enum SessionFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case active = "Active"
        case errors = "Errors"
        case completed = "Completed"

        var id: String { rawValue }
    }

    private var filteredSessions: [SessionSummary] {
        store.sessions.filter { session in
            let matchesFilter: Bool
            switch filter {
            case .all:
                matchesFilter = true
            case .active:
                matchesFilter = session.isActive
            case .errors:
                matchesFilter = session.status == .error
            case .completed:
                matchesFilter = session.status == .completed || session.status == .idle
            }

            guard matchesFilter else { return false }

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            return session.title.localizedCaseInsensitiveContains(query)
                || (session.model?.localizedCaseInsensitiveContains(query) ?? false)
                || (session.lastStepPreview?.localizedCaseInsensitiveContains(query) ?? false)
                || session.id.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                LazyVStack(spacing: 14) {
                    if store.isDemoMode {
                        demoModeBanner
                    }

                    summaryMetricsStrip
                    filterChipsRow

                    if store.isRefreshing && store.sessions.isEmpty {
                        ProgressView("Syncing sessions...")
                            .padding(.top, 48)
                    } else if filteredSessions.isEmpty {
                        emptyStateView
                            .padding(.top, 32)
                    } else {
                        ForEach(filteredSessions) { session in
                            NavigationLink(value: session.id) {
                                SessionRowCard(
                                    session: session,
                                    isPinnedToLiveActivity: store.activeLiveActivitySessionId == session.id
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    store.toggleLiveActivity(for: session)
                                } label: {
                                    Label(
                                        store.activeLiveActivitySessionId == session.id
                                            ? "End Live Activity"
                                            : "Pin to Dynamic Island",
                                        systemImage: "platter.filled.top.iphone"
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
            .background(groupedBackground)
            .navigationTitle("Antigravity")
            .searchable(text: $searchText, prompt: "Search sessions or models")
            .refreshable {
                await store.refreshAll()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ConnectionStatusPill()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.isPresentingPairingSheet = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                    .accessibilityLabel("Pair Workstation")
                }
            }
            .navigationDestination(for: String.self) { sessionId in
                if let session = store.sessions.first(where: { $0.id == sessionId }) {
                    SessionDetailView(session: session)
                } else {
                    ContentUnavailableView("Session Unavailable", systemImage: "doc.questionmark")
                }
            }
            .onChange(of: store.selectedSessionId) { _, newSessionId in
                if let newSessionId, !newSessionId.isEmpty {
                    navigationPath = [newSessionId]
                    store.selectedSessionId = nil
                }
            }
        }
    }

    private var demoModeBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles.tv")
                .font(.title3)
                .foregroundStyle(.indigo)

            VStack(alignment: .leading, spacing: 2) {
                Text("Demo Mode Active")
                    .font(.subheadline.weight(.semibold))
                Text("Showing sample Antigravity telemetry. Pair your workstation to monitor live sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button("Pair") {
                store.isPresentingPairingSheet = true
            }
            .font(.caption.weight(.bold))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.indigo.opacity(0.11), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.indigo.opacity(0.28), lineWidth: 1)
        )
    }

    private var summaryMetricsStrip: some View {
        HStack(spacing: 10) {
            MetricSummaryTile(
                title: "Active",
                value: "\(store.activeSessionCount)",
                subtitle: "\(store.sessions.count) total",
                systemImage: "bolt.circle.fill",
                tint: .indigo
            )

            MetricSummaryTile(
                title: "Tokens",
                value: store.health?.formattedTotalTokens ?? totalSessionTokensText,
                subtitle: "Cache \(store.health?.formattedCacheHitRate ?? averageCacheHitText)",
                systemImage: "chart.bar.fill",
                tint: .cyan
            )

            MetricSummaryTile(
                title: "Gates",
                value: "\(store.pendingApprovalCount)",
                subtitle: store.pendingApprovalCount > 0 ? "Action needed" : "All clear",
                systemImage: "exclamationmark.shield.fill",
                tint: store.pendingApprovalCount > 0 ? .orange : .green
            )
            .onTapGesture {
                store.selectedTab = .approvals
            }
        }
    }

    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SessionFilter.allCases) { item in
                    let isSelected = filter == item
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            filter = item
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(item.rawValue)
                                .font(.caption.weight(.semibold))
                            Text("\(count(for: item))")
                                .font(.caption2.monospacedDigit().weight(.bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    isSelected ? Color.white.opacity(0.24) : Color.secondary.opacity(0.16),
                                    in: Capsule()
                                )
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            isSelected ? Color.indigo : cardBackground,
                            in: Capsule()
                        )
                        .foregroundStyle(isSelected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label(
                searchText.isEmpty ? "No Matching Sessions" : "No Search Results",
                systemImage: "tray"
            )
        } description: {
            if !searchText.isEmpty {
                Text("No sessions matched \"\(searchText)\".")
            } else if filter != .all {
                Text("No sessions currently in the \(filter.rawValue.lowercased()) state.")
            } else {
                Text("Start an Antigravity conversation on your workstation or pair a bridge host to see live sessions here.")
            }
        } actions: {
            if filter != .all {
                Button("Show All Sessions") {
                    filter = .all
                }
                .buttonStyle(.bordered)
            } else if !store.hasPairedHosts {
                Button("Pair Workstation") {
                    store.isPresentingPairingSheet = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func count(for filter: SessionFilter) -> Int {
        switch filter {
        case .all: return store.sessions.count
        case .active: return store.sessions.filter(\.isActive).count
        case .errors: return store.sessions.filter { $0.status == .error }.count
        case .completed: return store.sessions.filter { $0.status == .completed || $0.status == .idle }.count
        }
    }

    private var totalSessionTokensText: String {
        let total = store.sessions.reduce(0) { $0 + $1.totalTokens }
        return TokenFormatter.format(total)
    }

    private var averageCacheHitText: String {
        let input = store.sessions.reduce(0) { $0 + $1.inputTokens }
        let cache = store.sessions.reduce(0) { $0 + $1.cacheReadTokens }
        return TokenFormatter.formatPercentage(TokenFormatter.cacheHitRate(inputTokens: input, cacheReadTokens: cache))
    }

    private var groupedBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color.clear
        #endif
    }

    private var cardBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color.secondary.opacity(0.12)
        #endif
    }
}

private struct SessionRowCard: View {
    let session: SessionSummary
    let isPinnedToLiveActivity: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                PulsingStatusDot(
                    color: statusColor,
                    isPulsing: session.status == .running
                )

                Text(session.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 4)

                if isPinnedToLiveActivity {
                    Image(systemName: "platter.filled.top.iphone")
                        .font(.caption)
                        .foregroundStyle(.indigo)
                }

                PillBadge(text: session.status.displayName, tint: statusColor)
            }

            if let preview = session.lastStepPreview, !preview.isEmpty {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let model = session.model, !model.isEmpty {
                        PillBadge(text: model, systemImage: "cpu", tint: .indigo)
                    }
                    if session.hasSwarm {
                        PillBadge(text: "Swarm", systemImage: "person.3.sequence.fill", tint: .purple)
                    }
                    if session.subagentCount > 0 {
                        PillBadge(
                            text: "\(session.subagentCount) subagent\(session.subagentCount == 1 ? "" : "s")",
                            systemImage: "point.3.connected.trianglepath.dotted",
                            tint: .cyan
                        )
                    }
                    if session.artifactCount > 0 {
                        PillBadge(
                            text: "\(session.artifactCount)",
                            systemImage: "doc.richtext",
                            tint: .blue
                        )
                    }
                    if session.taskCount > 0 {
                        PillBadge(
                            text: "\(session.taskCount)",
                            systemImage: "terminal",
                            tint: .teal
                        )
                    }
                }
            }

            HStack {
                Label("\(session.stepCount) steps", systemImage: "list.bullet.rectangle")
                Text("•")
                Text("\(session.formattedTotalTokens) tok")
                if session.cacheReadTokens > 0 {
                    Text("(\(session.formattedCacheHitRate) cache)")
                        .foregroundStyle(.green)
                }
                Spacer()
                Text(session.updatedAt, style: .relative)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(session.status == .error ? Color.red.opacity(0.35) : Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private var statusColor: Color {
        switch session.status {
        case .running: return .indigo
        case .waiting: return .orange
        case .error: return .red
        case .completed: return .green
        case .idle, .unknown: return .secondary
        }
    }

    private var cardBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color.secondary.opacity(0.12)
        #endif
    }
}
