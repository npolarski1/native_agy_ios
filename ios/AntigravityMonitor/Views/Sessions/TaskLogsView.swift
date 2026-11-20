import AntigravityCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct TaskLogsView: View {
    let tasksResponse: SessionTasksResponse?
    let isLoading: Bool

    @State private var expandedTaskIds: Set<String> = []

    var body: some View {
        if isLoading && tasksResponse == nil {
            ProgressView("Loading tasks & swarm telemetry...")
                .frame(maxWidth: .infinity, minHeight: 200)
        } else if let data = tasksResponse,
                  (!data.tasks.isEmpty || !data.subagents.isEmpty || !data.swarmEvents.isEmpty) {
            LazyVStack(alignment: .leading, spacing: 20) {
                if !data.swarmEvents.isEmpty {
                    swarmSection(events: data.swarmEvents)
                }
                if !data.subagents.isEmpty {
                    subagentsSection(subagents: data.subagents)
                }
                if !data.tasks.isEmpty {
                    backgroundTasksSection(tasks: data.tasks)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        } else {
            ContentUnavailableView {
                Label("No Background Tasks or Swarms", systemImage: "cpu")
            } description: {
                Text("Background command logs, invoked subagents, and multi-agent swarm events for this session will appear here.")
            }
            .padding(.top, 32)
        }
    }

    private func swarmSection(events: [SwarmEventItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Swarm Timeline (\(events.count))", systemImage: "person.3.sequence.fill")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(events) { event in
                    HStack(alignment: .top, spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(swarmColor(for: event.action).opacity(0.18))
                                .frame(width: 30, height: 30)
                            Image(systemName: swarmIcon(for: event.action))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(swarmColor(for: event.action))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(event.action.uppercased())
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(swarmColor(for: event.action))

                                if let target = event.target, !target.isEmpty {
                                    PillBadge(text: target, tint: .indigo)
                                }

                                Spacer()

                                Text("#\(event.stepIndex)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }

                            Text(event.summary)
                                .font(.subheadline)
                                .foregroundStyle(.primary)

                            Text(event.createdAt, format: .dateTime.hour().minute().second())
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private func subagentsSection(subagents: [SubagentInvocation]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Subagents (\(subagents.count))", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(subagents) { subagent in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            PillBadge(text: subagent.role, systemImage: "person.crop.circle", tint: .purple)
                            Text(subagent.typeName)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Step #\(subagent.stepIndex)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }

                        if !subagent.promptPreview.isEmpty {
                            Text(subagent.promptPreview)
                                .font(.footnote)
                                .foregroundStyle(.primary)
                                .lineLimit(4)
                        }

                        Text(subagent.createdAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private func backgroundTasksSection(tasks: [TaskLogItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Background Task Logs (\(tasks.count))", systemImage: "terminal.fill")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(tasks) { task in
                    let isExpanded = expandedTaskIds.contains(task.id)
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                if isExpanded {
                                    expandedTaskIds.remove(task.id)
                                } else {
                                    expandedTaskIds.insert(task.id)
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.plaintext.fill")
                                    .foregroundStyle(.cyan)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.filename)
                                        .font(.subheadline.monospaced().weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text(task.formattedSize)
                                        Text("•")
                                        Text(task.updatedAt, style: .relative)
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)

                        if isExpanded || tasks.count == 1 {
                            VStack(alignment: .trailing, spacing: 6) {
                                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                                    Text(task.tail.isEmpty ? "(empty log)" : task.tail)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.green)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(10)
                                }
                                .frame(maxHeight: 240)
                                .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                                Button {
                                    UIFormatters.copyToPasteboard(task.tail)
                                } label: {
                                    Label("Copy Tail", systemImage: "doc.on.doc")
                                        .font(.caption2)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .padding(12)
                    .background(cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private func swarmIcon(for action: String) -> String {
        switch action.lowercased() {
        case "add", "spawn": return "person.badge.plus"
        case "kill", "stop": return "xmark.octagon.fill"
        case "post", "message": return "bubble.left.fill"
        case "model": return "cpu"
        case "done": return "checkmark.seal.fill"
        default: return "bolt.fill"
        }
    }

    private func swarmColor(for action: String) -> Color {
        switch action.lowercased() {
        case "add", "spawn": return .indigo
        case "kill", "stop": return .red
        case "post", "message": return .cyan
        case "done": return .green
        default: return .purple
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
