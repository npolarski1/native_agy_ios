import AntigravityCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct HostTelemetryView: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    hostSwitcherCard
                    connectionStatusCard

                    if let health = store.health {
                        workstationDetailsCard(health: health)
                        tokenAnalyticsCard(health: health)
                    } else {
                        ContentUnavailableView {
                            Label("No Telemetry Yet", systemImage: "waveform.path.ecg")
                        } description: {
                            Text("Pair a workstation or enable Demo Mode to view live workstation health and token usage.")
                        }
                        .padding(.top, 24)
                    }

                    if !store.recentHookEvents.isEmpty {
                        recentEventsCard
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
            .background(groupedBackground)
            .navigationTitle("Host Telemetry")
            .refreshable {
                await store.refreshAll()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.isPresentingPairingSheet = true
                    } label: {
                        Label("Pair Host", systemImage: "plus.circle")
                    }
                }
            }
        }
    }

    private var hostSwitcherCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.indigo.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: "desktopcomputer")
                    .font(.title3)
                    .foregroundStyle(.indigo)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(store.isDemoMode ? "Demo Workstation" : (store.activeHost?.name ?? "No Host Paired"))
                    .font(.headline)
                    .lineLimit(1)
                Text(store.isDemoMode ? "Simulated bridge telemetry" : (store.activeHost?.displayHost ?? "Tap Pair to connect"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !store.hosts.isEmpty {
                Menu {
                    ForEach(store.hosts) { host in
                        Button {
                            Task { await store.selectHost(host) }
                        } label: {
                            if host.id == store.activeHost?.id && !store.isDemoMode {
                                Label(host.name, systemImage: "checkmark")
                            } else {
                                Text(host.name)
                            }
                        }
                    }
                    Divider()
                    Button {
                        store.isPresentingPairingSheet = true
                    } label: {
                        Label("Pair Another Host...", systemImage: "qrcode.viewfinder")
                    }
                } label: {
                    Label("Switch", systemImage: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button("Pair") {
                    store.isPresentingPairingSheet = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var connectionStatusCard: some View {
        HStack(spacing: 12) {
            PulsingStatusDot(
                color: connectionColor,
                isPulsing: store.connectionState.isConnected && !store.isDemoMode,
                size: 10
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(store.isDemoMode ? "Demo Mode" : "WebSocket Stream: \(store.connectionState.displayLabel)")
                    .font(.subheadline.weight(.semibold))
                if let lastRefreshed = store.lastRefreshedAt {
                    Text("Synced \(lastRefreshed, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Waiting for initial sync")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                Task { await store.refreshAll() }
            } label: {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func workstationDetailsCard(health: HostHealth) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Workstation", systemImage: "server.rack")
                    .font(.headline)
                Spacer()
                PillBadge(text: "API v\(health.apiVersion)", tint: .indigo)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                MetricSummaryTile(
                    title: "Hostname",
                    value: health.hostname,
                    systemImage: "macstudio",
                    tint: .indigo
                )
                MetricSummaryTile(
                    title: "Platform",
                    value: health.platform,
                    systemImage: "cpu",
                    tint: .cyan
                )
                MetricSummaryTile(
                    title: "Bridge Uptime",
                    value: health.formattedUptime,
                    systemImage: "clock.fill",
                    tint: .green
                )
                MetricSummaryTile(
                    title: "Sessions",
                    value: "\(health.activeSessionCount) / \(health.sessionCount)",
                    subtitle: "\(health.pendingApprovalCount) pending gates",
                    systemImage: "sparkles.rectangle.stack",
                    tint: .purple
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Brain Directory", systemImage: "folder.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    PillBadge(
                        text: health.brainDirExists ? "Verified" : "Missing",
                        systemImage: health.brainDirExists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        tint: health.brainDirExists ? .green : .red
                    )
                }
                Text(health.brainDir)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(14)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func tokenAnalyticsCard(health: HostHealth) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Cumulative Token Telemetry", systemImage: "chart.bar.xaxis")
                    .font(.headline)
                Spacer()
                Text(health.formattedTotalTokens)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.indigo)
            }

            HStack(spacing: 10) {
                tokenColumn(label: "Input", value: TokenFormatter.format(health.totalInputTokens), tint: .indigo)
                tokenColumn(label: "Cache Read", value: TokenFormatter.format(health.totalCacheReadTokens), tint: .green)
                tokenColumn(label: "Output", value: TokenFormatter.format(health.totalOutputTokens), tint: .cyan)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Prompt Cache Hit Rate")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(health.formattedCacheHitRate)
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(.green)
                }

                ProgressView(value: health.cacheHitRate)
                    .tint(.green)
            }
        }
        .padding(14)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func tokenColumn(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var recentEventsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Live Hook Stream", systemImage: "bolt.horizontal.fill")
                .font(.headline)

            ForEach(Array(store.recentHookEvents.prefix(12).enumerated()), id: \.offset) { _, event in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Color.indigo)
                        .frame(width: 7, height: 7)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(event.hookEventName ?? event.type.rawValue)
                                .font(.caption.monospaced().weight(.semibold))
                            Spacer()
                            Text(event.timestamp, format: .dateTime.hour().minute().second())
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        if let message = event.message, !message.isEmpty {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(14)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var connectionColor: Color {
        if store.isDemoMode { return .indigo }
        switch store.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .failed: return .red
        case .disconnected: return .secondary
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
