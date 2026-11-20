import AntigravityCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct PairingSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MonitorStore.self) private var store

    @State private var selectedMode: PairingMode = .qr
    @State private var bonjour = BonjourDiscovery()

    // Manual form fields
    @State private var hostName = ""
    @State private var baseURLText = ""
    @State private var bearerToken = ""

    // Verification & pairing status
    @State private var isTesting = false
    @State private var isPairing = false
    @State private var verifiedHealth: HostHealth?
    @State private var statusError: String?
    @State private var resolvingBonjourHostId: String?

    enum PairingMode: String, CaseIterable, Identifiable {
        case qr = "Scan QR"
        case nearby = "Nearby LAN"
        case manual = "Manual"

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Pairing Method", selection: $selectedMode) {
                    ForEach(PairingMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                switch selectedMode {
                case .qr:
                    qrTabContent
                case .nearby:
                    nearbyLanTabContent
                case .manual:
                    manualTabContent
                }
            }
            .navigationTitle("Pair Workstation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .onChange(of: selectedMode) { _, newMode in
                if newMode == .nearby {
                    bonjour.start()
                } else {
                    bonjour.stop()
                }
            }
            .onDisappear {
                bonjour.stop()
            }
        }
    }

    // MARK: - 1. QR Scanner Tab

    private var qrTabContent: some View {
        VStack(spacing: 12) {
            QRScannerView { rawCode in
                handleScannedCode(rawCode)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal)

            if isPairing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Verifying and pairing workstation...")
                        .font(.subheadline)
                }
                .padding(.bottom, 12)
            } else if let statusError {
                Text(statusError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.bottom, 12)
            } else {
                Text("Run `python -m antigravity_bridge serve` on your workstation to display the QR code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.bottom, 12)
            }
        }
    }

    // MARK: - 2. Nearby LAN Bonjour Tab

    private var nearbyLanTabContent: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    if bonjour.isSearching {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "wifi")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bonjour.isSearching ? "Scanning Local Network..." : "Scanner Idle")
                            .font(.subheadline.weight(.semibold))
                        Text("Service type: \(BonjourDiscovery.serviceType)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(bonjour.isSearching ? "Restart" : "Scan") {
                        bonjour.start()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let bonjourError = bonjour.lastError {
                Section {
                    Label(bonjourError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Discovered Bridges (\(bonjour.hosts.count))") {
                if bonjour.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("No Nearby Bridges Found", systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text("Ensure your workstation bridge is running on the same Wi-Fi network, or connect remotely over Tailscale via Manual pairing.")
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(bonjour.hosts) { discovered in
                        Button {
                            selectDiscoveredHost(discovered)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "desktopcomputer")
                                    .font(.title3)
                                    .foregroundStyle(.indigo)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(discovered.name)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    if let url = discovered.suggestedURL {
                                        Text(url.absoluteString)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("\(discovered.type) (\(discovered.domain))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if resolvingBonjourHostId == discovered.id {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.right.circle.fill")
                                        .foregroundStyle(.indigo)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 3. Manual Configuration Tab

    private var manualTabContent: some View {
        Form {
            Section {
                TextField("Display Name (e.g. Mac Studio)", text: $hostName)

                TextField("http://192.168.1.42:8765", text: $baseURLText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.body.monospaced())

                SecureField("Bearer Token", text: $bearerToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            } header: {
                Text("Bridge Connection")
            } footer: {
                Text("Supports local Wi-Fi IPs, Bonjour `.local` hostnames, Tailscale (`http://100.x.y.z:8765` or `https://host.ts.net`), and Cloudflare Tunnels.")
            }

            if let verifiedHealth {
                Section("Verified Bridge") {
                    LabeledContent("Hostname", value: verifiedHealth.hostname)
                    LabeledContent("Platform", value: verifiedHealth.platform)
                    LabeledContent("API Version", value: verifiedHealth.apiVersion)
                    LabeledContent("Sessions Found", value: "\(verifiedHealth.sessionCount)")
                    LabeledContent("Brain Directory", value: verifiedHealth.brainDirExists ? "Found" : "Missing")
                }
            }

            if let statusError {
                Section {
                    Label(statusError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await runConnectionTest() }
                } label: {
                    HStack {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "network")
                        }
                        Text(isTesting ? "Testing Bridge..." : "Test Connection")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(isTesting || isPairing || !hasValidManualInputs)

                Button {
                    Task { await saveAndPairManualHost() }
                } label: {
                    HStack {
                        if isPairing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.shield.fill")
                        }
                        Text(isPairing ? "Pairing..." : "Save & Connect")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTesting || isPairing || !hasValidManualInputs)
            }
        }
    }

    // MARK: - Actions

    private var hasValidManualInputs: Bool {
        !baseURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func handleScannedCode(_ rawCode: String) {
        statusError = nil
        do {
            let payload = try PairingURI.parse(rawCode)
            hostName = payload.name
            baseURLText = payload.baseURL.absoluteString
            bearerToken = payload.token

            Task {
                isPairing = true
                defer { isPairing = false }
                do {
                    try await store.pairHost(
                        baseURL: payload.baseURL,
                        token: payload.token,
                        name: payload.name
                    )
                    dismiss()
                } catch {
                    statusError = error.localizedDescription
                    selectedMode = .manual
                }
            }
        } catch {
            statusError = error.localizedDescription
        }
    }

    private func selectDiscoveredHost(_ discovered: DiscoveredHost) {
        resolvingBonjourHostId = discovered.id
        statusError = nil
        Task {
            let resolved = await bonjour.resolve(discovered)
            resolvingBonjourHostId = nil
            hostName = resolved.name
            if let url = resolved.suggestedURL {
                baseURLText = url.absoluteString
            } else if let host = resolved.host {
                let port = resolved.port ?? 8765
                baseURLText = "http://\(host):\(port)"
            }
            selectedMode = .manual
        }
    }

    private func runConnectionTest() async {
        statusError = nil
        verifiedHealth = nil
        isTesting = true
        defer { isTesting = false }

        do {
            let url = try PairingURI.normalizeBaseURL(baseURLText)
            let token = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let health = try await store.testConnection(baseURL: url, token: token)
            verifiedHealth = health
            if hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hostName = health.hostname
            }
        } catch {
            statusError = error.localizedDescription
        }
    }

    private func saveAndPairManualHost() async {
        statusError = nil
        isPairing = true
        defer { isPairing = false }

        do {
            let url = try PairingURI.normalizeBaseURL(baseURLText)
            let token = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
            try await store.pairHost(baseURL: url, token: token, name: hostName)
            dismiss()
        } catch {
            statusError = error.localizedDescription
        }
    }
}
