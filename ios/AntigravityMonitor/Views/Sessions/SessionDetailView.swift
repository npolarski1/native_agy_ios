import AntigravityCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct SessionDetailView: View {
    @Environment(MonitorStore.self) private var store
    let session: SessionSummary

    @State private var selectedSegment: DetailSegment = .transcript
    @State private var loadFullTranscript = false

    enum DetailSegment: String, CaseIterable, Identifiable {
        case transcript = "Transcript"
        case artifacts = "Artifacts"
        case tasks = "Tasks & Swarms"

        var id: String { rawValue }
    }

    private var liveSession: SessionSummary {
        store.sessions.first(where: { $0.id == session.id }) ?? session
    }

    private var steps: [TranscriptStep] {
        store.transcriptsBySession[session.id] ?? []
    }

    private var artifacts: [ArtifactItem] {
        store.artifactsBySession[session.id] ?? []
    }

    private var tasksResponse: SessionTasksResponse? {
        store.tasksBySession[session.id]
    }

    private var isLoadingDetails: Bool {
        store.loadingDetailSessionIds.contains(session.id)
    }

    private var isPinnedToLiveActivity: Bool {
        store.activeLiveActivitySessionId == session.id
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                headerCard
                    .padding(.horizontal)

                Picker("Section", selection: $selectedSegment) {
                    ForEach(DetailSegment.allCases) { segment in
                        Text(segmentTitle(for: segment)).tag(segment)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                switch selectedSegment {
                case .transcript:
                    transcriptContent
                case .artifacts:
                    ArtifactListView(
                        sessionId: session.id,
                        artifacts: artifacts,
                        isLoading: isLoadingDetails,
                        loadText: { sid, relPath in
                            try await store.fetchArtifactText(sessionId: sid, relativePath: relPath)
                        },
                        loadBinary: { sid, relPath in
                            await store.fetchArtifactBinary(sessionId: sid, relativePath: relPath)
                        }
                    )
                case .tasks:
                    TaskLogsView(
                        tasksResponse: tasksResponse,
                        isLoading: isLoadingDetails
                    )
                }
            }
            .padding(.vertical, 10)
        }
        .background(groupedBackground)
        .navigationTitle(liveSession.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    store.toggleLiveActivity(for: liveSession)
                } label: {
                    Image(systemName: isPinnedToLiveActivity ? "platter.filled.top.iphone" : "platter.top.iphone")
                }
                .accessibilityLabel(isPinnedToLiveActivity ? "End Live Activity" : "Pin to Live Activity")

                Button {
                    Task {
                        await store.loadSessionDetails(sessionId: session.id, fullTranscript: loadFullTranscript)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .refreshable {
            await store.loadSessionDetails(sessionId: session.id, fullTranscript: loadFullTranscript)
        }
        .task(id: session.id) {
            await store.loadSessionDetails(sessionId: session.id, fullTranscript: loadFullTranscript)
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                PulsingStatusDot(
                    color: statusColor,
                    isPulsing: liveSession.status == .running
                )

                Text(liveSession.status.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(statusColor)

                if let model = liveSession.model, !model.isEmpty {
                    PillBadge(text: model, systemImage: "cpu", tint: .indigo)
                }

                Spacer()

                Text(liveSession.updatedAt, style: .relative)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                compactStat(label: "Steps", value: "\(liveSession.stepCount)")
                Divider().frame(height: 26)
                compactStat(label: "Input", value: TokenFormatter.format(liveSession.inputTokens))
                Divider().frame(height: 26)
                compactStat(label: "Cache", value: liveSession.formattedCacheHitRate, valueColor: .green)
                Divider().frame(height: 26)
                compactStat(label: "Output", value: TokenFormatter.format(liveSession.outputTokens))
            }

            HStack(spacing: 8) {
                if liveSession.hasSwarm {
                    PillBadge(text: "Swarm Session", systemImage: "person.3.sequence.fill", tint: .purple)
                }
                if liveSession.subagentCount > 0 {
                    PillBadge(text: "\(liveSession.subagentCount) Subagents", systemImage: "point.3.connected.trianglepath.dotted", tint: .cyan)
                }
                Spacer()
                Button {
                    store.toggleLiveActivity(for: liveSession)
                } label: {
                    Label(
                        isPinnedToLiveActivity ? "Live Activity On" : "Live Activity",
                        systemImage: isPinnedToLiveActivity ? "checkmark.circle.fill" : "sparkles"
                    )
                    .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(isPinnedToLiveActivity ? .green : .indigo)
            }
        }
        .padding(14)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if isLoadingDetails && steps.isEmpty {
            ProgressView("Loading transcript...")
                .frame(maxWidth: .infinity, minHeight: 200)
        } else if steps.isEmpty {
            ContentUnavailableView {
                Label("Empty Transcript", systemImage: "text.bubble")
            } description: {
                Text("No transcript steps have been recorded for this conversation yet.")
            }
            .padding(.top, 24)
        } else {
            LazyVStack(spacing: 14) {
                if let total = store.totalStepsBySession[session.id], total > steps.count {
                    HStack {
                        Text("Showing \(steps.count) of \(total) steps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                ForEach(steps) { step in
                    TranscriptStepCard(
                        step: step,
                        loadMediaData: { path in
                            await store.fetchMediaData(urlPath: path)
                        },
                        onLoadFullTranscript: step.isTruncated ? {
                            loadFullTranscript = true
                            Task {
                                await store.loadTranscript(sessionId: session.id, full: true)
                            }
                        } : nil
                    )
                }
            }
            .padding(.horizontal)
        }
    }

    private func compactStat(label: String, value: String, valueColor: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func segmentTitle(for segment: DetailSegment) -> String {
        switch segment {
        case .transcript:
            return "Transcript (\(max(steps.count, liveSession.stepCount)))"
        case .artifacts:
            let count = max(artifacts.count, liveSession.artifactCount)
            return count > 0 ? "Artifacts (\(count))" : "Artifacts"
        case .tasks:
            let count = (tasksResponse?.tasks.count ?? liveSession.taskCount)
                + (tasksResponse?.swarmEvents.count ?? 0)
            return count > 0 ? "Tasks (\(count))" : "Tasks"
        }
    }

    private var statusColor: Color {
        switch liveSession.status {
        case .running: return .indigo
        case .waiting: return .orange
        case .error: return .red
        case .completed: return .green
        case .idle, .unknown: return .secondary
        }
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
