import AntigravityCore
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(MonitorStore.self) private var store
    @State private var copiedHooksSnippet = false
    @State private var copiedBridgeCommand = false

    private let hooksSnippet = """
    {
      "antigravity-monitor": {
        "enabled": true,
        "PreInvocation": [
          { "type": "command", "command": "python3 /path/to/bridge/hooks/antigravity_hook.py --event PreInvocation", "timeout": 30 }
        ],
        "PostInvocation": [
          { "type": "command", "command": "python3 /path/to/bridge/hooks/antigravity_hook.py --event PostInvocation", "timeout": 30 }
        ],
        "PreToolUse": [
          {
            "matcher": "run_command|write_file|edit_file",
            "hooks": [
              { "type": "command", "command": "python3 /path/to/bridge/hooks/antigravity_hook.py --event PreToolUse --timeout 55", "timeout": 60 }
            ]
          }
        ],
        "PostToolUse": [
          {
            "matcher": "*",
            "hooks": [
              { "type": "command", "command": "python3 /path/to/bridge/hooks/antigravity_hook.py --event PostToolUse", "timeout": 30 }
            ]
          }
        ],
        "Stop": [
          { "type": "command", "command": "python3 /path/to/bridge/hooks/antigravity_hook.py --event Stop", "timeout": 30 }
        ]
      }
    }
    """

    private let bridgeQuickstartCommand = "python -m antigravity_bridge install-hooks && python -m antigravity_bridge serve"

    var body: some View {
        @Bindable var bindableStore = store
        @Bindable var notifications = store.notifications

        NavigationStack {
            Form {
                Section {
                    if store.hosts.isEmpty {
                        Text("No workstations paired yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.hosts) { host in
                            Button {
                                Task { await store.selectHost(host) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(host.name)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text(host.baseURL.absoluteString)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if host.id == store.activeHost?.id && !store.isDemoMode {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task { await store.removeHost(host) }
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }

                    Button {
                        store.isPresentingPairingSheet = true
                    } label: {
                        Label("Pair New Workstation", systemImage: "qrcode.viewfinder")
                    }
                } header: {
                    Text("Paired Workstations")
                } footer: {
                    Text("Bearer tokens are stored locally in the iOS Keychain. Swipe left on a workstation to remove it.")
                }

                Section {
                    Toggle("Demo Mode", isOn: Binding(
                        get: { store.isDemoMode },
                        set: { enabled in
                            Task { await store.setDemoMode(enabled) }
                        }
                    ))
                } header: {
                    Text("Display Mode")
                } footer: {
                    Text("Demo Mode activates automatically only when no workstation is paired. Toggle it anytime to preview sample sessions and Dynamic Island Live Activities.")
                }

                Section {
                    HStack {
                        Text("Permission Status")
                        Spacer()
                        Text(notificationStatusText)
                            .foregroundStyle(notificationStatusColor)
                    }

                    if store.notifications.authorizationStatus != .authorized {
                        Button("Enable Push / Local Alerts") {
                            Task {
                                _ = await store.notifications.requestAuthorization()
                            }
                        }
                    }

                    Toggle("Tool Approval Requests", isOn: $notifications.notifyOnApprovals)
                    Toggle("Completed Agent Turns (Stop)", isOn: $notifications.notifyOnCompletion)
                    Toggle("Session Errors", isOn: $notifications.notifyOnErrors)
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Approval alerts include native Allow and Deny actions directly from the iOS notification banner.")
                }

                Section {
                    Toggle("Auto-Start Live Activities", isOn: $bindableStore.liveActivitiesEnabled)

                    if store.activeLiveActivitySessionId != nil {
                        Button(role: .destructive) {
                            store.stopLiveActivity()
                        } label: {
                            Label("End Active Live Activity", systemImage: "xmark.circle")
                        }
                    }
                } header: {
                    Text("Live Activities & Dynamic Island")
                } footer: {
                    Text("Shows your active Antigravity session status, step count, and pending approval badge on the Lock Screen and Dynamic Island.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Quickstart CLI")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(bridgeQuickstartCommand)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                        Button {
                            UIFormatters.copyToPasteboard(bridgeQuickstartCommand)
                            copiedBridgeCommand = true
                        } label: {
                            Label(copiedBridgeCommand ? "Copied Command" : "Copy CLI Command", systemImage: copiedBridgeCommand ? "checkmark" : "doc.on.doc")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("~/.gemini/config/hooks.json")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(hooksSnippet)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Button {
                            UIFormatters.copyToPasteboard(hooksSnippet)
                            copiedHooksSnippet = true
                        } label: {
                            Label(copiedHooksSnippet ? "Copied hooks.json" : "Copy hooks.json Snippet", systemImage: copiedHooksSnippet ? "checkmark" : "doc.on.doc")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Workstation Bridge & Official Hooks Setup")
                }

                Section("About") {
                    LabeledContent("Application", value: "Antigravity Monitor")
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Architecture", value: "Self-Hosted • Zero Relay")
                    LabeledContent("License", value: "MIT Open Source")
                }
            }
            .navigationTitle("Settings")
            .task {
                await store.notifications.refreshAuthorizationStatus()
            }
        }
    }

    private var notificationStatusText: String {
        switch store.notifications.authorizationStatus {
        case .authorized: return "Authorized"
        case .provisional: return "Provisional"
        case .ephemeral: return "Ephemeral"
        case .denied: return "Denied"
        case .notDetermined: return "Not Requested"
        @unknown default: return "Unknown"
        }
    }

    private var notificationStatusColor: Color {
        switch store.notifications.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .green
        case .denied: return .red
        default: return .secondary
        }
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
