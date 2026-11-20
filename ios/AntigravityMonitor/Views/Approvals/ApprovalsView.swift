import AntigravityCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct ApprovalsView: View {
    @Environment(MonitorStore.self) private var store

    @State private var denyTarget: ApprovalRequest?
    @State private var denyReasonText = ""
    @State private var allowHapticTrigger = 0
    @State private var denyHapticTrigger = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if store.isDemoMode {
                        demoNoticeStrip
                    }

                    pendingSection

                    if !store.resolvedApprovals.isEmpty {
                        historySection
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
            .background(groupedBackground)
            .navigationTitle("Approvals")
            .refreshable {
                await store.refreshAll()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ConnectionStatusPill()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.refreshAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sensoryFeedback(.success, trigger: allowHapticTrigger)
            .sensoryFeedback(.warning, trigger: denyHapticTrigger)
            .sheet(item: $denyTarget) { approval in
                DenyReasonSheet(
                    approval: approval,
                    reasonText: $denyReasonText,
                    onConfirmDeny: { reason in
                        let cleaned = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                        denyHapticTrigger += 1
                        Task {
                            await store.submitApproval(
                                approvalId: approval.id,
                                decision: .deny,
                                reason: cleaned.isEmpty ? nil : cleaned
                            )
                        }
                    }
                )
                .presentationDetents([.medium])
            }
        }
    }

    private var demoNoticeStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.indigo)
            Text("Demo approvals simulate PreToolUse hooks locally. Pair your workstation for live gating.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
        .background(Color.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var pendingSection: some View {
        let pending = store.pendingApprovals
        if pending.isEmpty {
            ContentUnavailableView {
                Label("All Clear", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            } description: {
                Text("No pending PreToolUse approvals. When Antigravity requests permission to execute a gated tool, it will appear here and trigger an actionable notification.")
            }
            .padding(.vertical, 36)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Pending Action (\(pending.count))", systemImage: "hand.raised.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Spacer()
                }

                TimelineView(.periodic(from: .now, by: 1.0)) { context in
                    VStack(spacing: 14) {
                        ForEach(pending) { approval in
                            PendingApprovalCard(
                                approval: approval,
                                now: context.date,
                                isSubmitting: store.resolvingApprovalIds.contains(approval.id),
                                onAllow: {
                                    allowHapticTrigger += 1
                                    Task {
                                        await store.submitApproval(approvalId: approval.id, decision: .allow)
                                    }
                                },
                                onDenyQuick: {
                                    denyHapticTrigger += 1
                                    Task {
                                        await store.submitApproval(approvalId: approval.id, decision: .deny)
                                    }
                                },
                                onDenyWithReason: {
                                    denyReasonText = ""
                                    denyTarget = approval
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Recent History", systemImage: "clock.arrow.circlepath")
                .font(.headline)
                .padding(.top, 4)

            ForEach(store.resolvedApprovals) { item in
                ResolvedApprovalRow(approval: item)
            }
        }
    }

    private var groupedBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color.clear
        #endif
    }
}

private struct PendingApprovalCard: View {
    let approval: ApprovalRequest
    let now: Date
    let isSubmitting: Bool
    let onAllow: () -> Void
    let onDenyQuick: () -> Void
    let onDenyWithReason: () -> Void

    private var remaining: TimeInterval {
        approval.remainingSeconds(at: now)
    }

    private var totalWindow: TimeInterval {
        max(1, approval.expiresAt.timeIntervalSince(approval.createdAt))
    }

    private var progress: Double {
        min(1.0, max(0.0, remaining / totalWindow))
    }

    private var isUrgent: Bool {
        remaining <= 15
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.title3)
                    .foregroundStyle(isUrgent ? .red : .orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(approval.toolName)
                        .font(.headline.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(approval.hookEvent)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                countdownPill
            }

            ProgressView(value: progress)
                .tint(isUrgent ? .red : .orange)

            if !approval.summary.isEmpty {
                Text(approval.summary)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Tool Arguments")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        UIFormatters.copyToPasteboard(approval.prettyArgsJson)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }

                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    Text(approval.prettyArgsJson)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 160)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if let sessionId = approval.sessionId, !sessionId.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.caption2)
                    Text("Session: \(sessionId.prefix(12))...")
                        .font(.caption2.monospaced())
                }
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(role: .destructive, action: onDenyQuick) {
                    Label("Deny", systemImage: "xmark.circle.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isSubmitting || remaining <= 0)

                Button(action: onAllow) {
                    if isSubmitting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    } else {
                        Label("Allow", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(isSubmitting || remaining <= 0)
            }

            Button(action: onDenyWithReason) {
                Label("Deny with Custom Reason...", systemImage: "text.bubble")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .controlSize(.small)
            .disabled(isSubmitting || remaining <= 0)
        }
        .padding(14)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder((isUrgent ? Color.red : Color.orange).opacity(0.42), lineWidth: 1.5)
        )
    }

    private var countdownPill: some View {
        let secs = Int(ceil(remaining))
        return HStack(spacing: 4) {
            Image(systemName: "timer")
            Text(secs > 0 ? "\(secs)s" : "Expired")
        }
        .font(.caption.monospacedDigit().weight(.bold))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background((isUrgent ? Color.red : Color.orange).opacity(0.18), in: Capsule())
        .foregroundStyle(isUrgent ? .red : .orange)
    }

    private var cardBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color.secondary.opacity(0.12)
        #endif
    }
}

private struct ResolvedApprovalRow: View {
    let approval: ApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                Text(approval.toolName)
                    .font(.subheadline.monospaced().weight(.semibold))
                    .lineLimit(1)
                Spacer()
                PillBadge(text: approval.status.displayName, tint: statusColor)
            }

            if !approval.summary.isEmpty {
                Text(approval.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let reason = approval.decisionReason, !reason.isEmpty {
                Text("Reason: \(reason)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .italic()
            }

            HStack {
                Text(approval.hookEvent)
                Spacer()
                Text(approval.decidedAt ?? approval.expiresAt, style: .relative)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var statusIcon: String {
        switch approval.status {
        case .approved: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .expired: return "clock.badge.exclamationmark"
        case .pending: return "hourglass"
        }
    }

    private var statusColor: Color {
        switch approval.status {
        case .approved: return .green
        case .denied: return .red
        case .expired: return .secondary
        case .pending: return .orange
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

private struct DenyReasonSheet: View {
    @Environment(\.dismiss) private var dismiss
    let approval: ApprovalRequest
    @Binding var reasonText: String
    let onConfirmDeny: (String) -> Void

    private let quickReasons = [
        "Hold off until I review the diff",
        "Do not run destructive shell commands",
        "Use a safer read-only alternative",
        "Wait for CI tests to finish first"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Tool Being Denied") {
                    Text(approval.toolName)
                        .font(.headline.monospaced())
                    if !approval.summary.isEmpty {
                        Text(approval.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Reason Sent Back to Antigravity") {
                    TextField("Optional feedback for the agent...", text: $reasonText, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("Quick Presets") {
                    ForEach(quickReasons, id: \.self) { preset in
                        Button(preset) {
                            reasonText = preset
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Deny Tool Call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Deny", role: .destructive) {
                        onConfirmDeny(reasonText)
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }
}
