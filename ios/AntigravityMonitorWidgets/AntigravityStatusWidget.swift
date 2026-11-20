import SwiftUI
import WidgetKit

struct AntigravityStatusEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct AntigravityStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> AntigravityStatusEntry {
        AntigravityStatusEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (AntigravityStatusEntry) -> Void) {
        let snapshot = WidgetSnapshot.load() ?? .placeholder
        completion(AntigravityStatusEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AntigravityStatusEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshot.load() ?? .placeholder
        let entry = AntigravityStatusEntry(date: now, snapshot: snapshot)
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: now) ?? now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct AntigravityStatusWidget: Widget {
    let kind: String = "AntigravityStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AntigravityStatusProvider()) { entry in
            AntigravityStatusWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Antigravity Monitor")
        .description("Live session activity, pending tool approvals, and token usage from your workstation.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct AntigravityStatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AntigravityStatusEntry

    var body: some View {
        switch family {
        case .systemSmall:
            smallView
        default:
            mediumView
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Circle()
                    .fill(entry.snapshot.isConnected ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(entry.snapshot.hostName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if entry.snapshot.isDemoMode {
                    Text("DEMO")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.indigo.opacity(0.2), in: Capsule())
                        .foregroundStyle(.indigo)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(entry.snapshot.activeSessionCount)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("active")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if entry.snapshot.pendingApprovalCount > 0 {
                Label("\(entry.snapshot.pendingApprovalCount) Approval", systemImage: "exclamationmark.shield.fill")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.22), in: Capsule())
                    .foregroundStyle(.orange)
            } else {
                Label("\(WidgetSnapshot.formatCompactTokens(entry.snapshot.totalTokens)) tok", systemImage: "bolt.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if let top = entry.snapshot.topSessions.first {
                Text(top.title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            } else {
                Text("No active sessions")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var mediumView: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(entry.snapshot.isConnected ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(entry.snapshot.hostName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.snapshot.activeSessionCount) / \(entry.snapshot.totalSessionCount)")
                        .font(.title2.weight(.bold).monospacedDigit())
                    Text("Active Sessions")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if entry.snapshot.pendingApprovalCount > 0 {
                    Label("\(entry.snapshot.pendingApprovalCount) Pending", systemImage: "hand.raised.fill")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                } else {
                    Label("\(WidgetSnapshot.formatCompactTokens(entry.snapshot.totalTokens)) tokens", systemImage: "waveform.path.ecg")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 120, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                if entry.snapshot.topSessions.isEmpty {
                    Spacer()
                    Text("No sessions detected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ForEach(entry.snapshot.topSessions.prefix(3)) { session in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(color(for: session.status))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(session.title)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text("\(session.model) • \(session.stepCount) steps")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func color(for status: String) -> Color {
        switch status.lowercased() {
        case "running": return .indigo
        case "waiting": return .orange
        case "error": return .red
        case "completed": return .green
        default: return .secondary
        }
    }
}
