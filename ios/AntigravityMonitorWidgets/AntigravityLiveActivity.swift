import SwiftUI
import WidgetKit
#if canImport(UIKit)
import UIKit
#endif

#if canImport(ActivityKit)
import ActivityKit

struct AntigravityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AntigravityActivityAttributes.self) { context in
            LockScreenLiveActivityView(context: context)
                .activityBackgroundTint(activityTintColor)
                .activitySystemActionForegroundColor(.indigo)
                .widgetURL(destinationURL(for: context))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        statusIcon(for: context.state)
                            .font(.headline)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(statusDisplayText(for: context.state))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(statusColor(for: context.state))
                            Text(context.attributes.hostName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        if context.state.pendingApprovals > 0 {
                            Label("\(context.state.pendingApprovals) Gate", systemImage: "exclamationmark.shield.fill")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.24), in: Capsule())
                                .foregroundStyle(.orange)
                        } else {
                            Text("Step \(context.state.stepCount)")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.primary)
                        }

                        Text(WidgetSnapshot.formatCompactTokens(context.state.totalTokens) + " tok")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !context.state.lastPreview.isEmpty {
                            Text(context.state.lastPreview)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        HStack {
                            Label(context.state.model, systemImage: "cpu")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Spacer()

                            Text(context.state.updatedAt, style: .relative)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 2)
                }
            } compactLeading: {
                statusIcon(for: context.state)
                    .font(.caption.weight(.bold))
                    .padding(.leading, 2)
            } compactTrailing: {
                if context.state.pendingApprovals > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "hand.raised.fill")
                            .font(.caption2)
                        Text("\(context.state.pendingApprovals)")
                            .font(.caption2.monospacedDigit().weight(.bold))
                    }
                    .foregroundStyle(.orange)
                    .padding(.trailing, 2)
                } else {
                    Text("\(context.state.stepCount)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 2)
                }
            } minimal: {
                statusIcon(for: context.state)
                    .font(.caption2.weight(.bold))
            }
            .widgetURL(destinationURL(for: context))
            .keylineTint(statusColor(for: context.state))
        }
    }

    private var activityTintColor: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemBackground).opacity(0.92)
        #else
        Color.black.opacity(0.85)
        #endif
    }

    private func destinationURL(for context: ActivityViewContext<AntigravityActivityAttributes>) -> URL? {
        if context.state.pendingApprovals > 0 {
            return URL(string: "agymon://approvals")
        }
        return URL(string: "agymon://session/\(context.attributes.sessionId)")
    }

    @ViewBuilder
    private func statusIcon(for state: AntigravityActivityAttributes.ContentState) -> some View {
        if state.pendingApprovals > 0 {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
        } else {
            switch state.status.lowercased() {
            case "running":
                Image(systemName: "sparkles")
                    .foregroundStyle(.indigo)
            case "waiting":
                Image(systemName: "clock.badge.questionmark")
                    .foregroundStyle(.orange)
            case "error":
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            case "completed":
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            default:
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusColor(for state: AntigravityActivityAttributes.ContentState) -> Color {
        if state.pendingApprovals > 0 {
            return .orange
        }
        switch state.status.lowercased() {
        case "running": return .indigo
        case "waiting": return .orange
        case "error": return .red
        case "completed": return .green
        default: return .secondary
        }
    }

    private func statusDisplayText(for state: AntigravityActivityAttributes.ContentState) -> String {
        if state.pendingApprovals > 0 {
            return "Approval Needed"
        }
        switch state.status.lowercased() {
        case "running": return "Running"
        case "waiting": return "Waiting"
        case "error": return "Error"
        case "completed": return "Completed"
        default: return "Idle"
        }
    }
}

private struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<AntigravityActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)

                Text(context.state.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                if context.state.pendingApprovals > 0 {
                    Label("\(context.state.pendingApprovals) Pending", systemImage: "hand.raised.fill")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                } else {
                    Text(context.state.status.capitalized)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(statusColor.opacity(0.16), in: Capsule())
                        .foregroundStyle(statusColor)
                }
            }

            if !context.state.lastPreview.isEmpty {
                Text(context.state.lastPreview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                Label(context.attributes.hostName, systemImage: "desktopcomputer")
                    .lineLimit(1)
                Label(context.state.model, systemImage: "cpu")
                    .lineLimit(1)
                Spacer()
                Text("\(context.state.stepCount) steps")
                    .monospacedDigit()
                Text("•")
                Text(WidgetSnapshot.formatCompactTokens(context.state.totalTokens))
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private var statusColor: Color {
        if context.state.pendingApprovals > 0 {
            return .orange
        }
        switch context.state.status.lowercased() {
        case "running": return .indigo
        case "waiting": return .orange
        case "error": return .red
        case "completed": return .green
        default: return .secondary
        }
    }
}
#endif
