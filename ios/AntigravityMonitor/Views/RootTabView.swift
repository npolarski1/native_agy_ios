import AntigravityCore
import SwiftUI

struct RootTabView: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        @Bindable var bindableStore = store

        TabView(selection: $bindableStore.selectedTab) {
            SessionListView()
                .tabItem {
                    Label("Sessions", systemImage: "sparkles.rectangle.stack")
                }
                .tag(MonitorStore.AppTab.sessions)

            ApprovalsView()
                .tabItem {
                    Label("Approvals", systemImage: "checkmark.shield.fill")
                }
                .badge(store.pendingApprovalCount)
                .tag(MonitorStore.AppTab.approvals)

            HostTelemetryView()
                .tabItem {
                    Label("Host", systemImage: "gauge.with.dots.needle.67percent")
                }
                .tag(MonitorStore.AppTab.telemetry)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(MonitorStore.AppTab.settings)
        }
        .sheet(isPresented: $bindableStore.isPresentingPairingSheet) {
            PairingSheetView()
                .environment(store)
        }
        .alert(
            "Connection Notice",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.clearError() } }
            )
        ) {
            Button("OK", role: .cancel) {
                store.clearError()
            }
        } message: {
            Text(store.lastError ?? "")
        }
    }
}

struct ConnectionStatusPill: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        Button {
            store.isPresentingPairingSheet = true
        } label: {
            HStack(spacing: 6) {
                PulsingStatusDot(
                    color: dotColor,
                    isPulsing: store.connectionState.isConnected && !store.isDemoMode,
                    size: 7
                )
                Text(store.statusDisplayText)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(dotColor.opacity(0.14), in: Capsule())
            .foregroundStyle(dotColor)
        }
        .buttonStyle(.plain)
    }

    private var dotColor: Color {
        if store.isDemoMode {
            return .indigo
        }
        switch store.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .failed: return .red
        case .disconnected: return .secondary
        }
    }
}
