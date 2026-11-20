import AntigravityCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct TranscriptStepCard: View {
    let step: TranscriptStep
    let loadMediaData: @MainActor (String) async -> Data?
    var onLoadFullTranscript: (() -> Void)? = nil

    @State private var showThinking = false
    @State private var expandedToolIds: Set<String> = []

    var body: some View {
        VStack(alignment: step.isUser ? .trailing : .leading, spacing: 8) {
            headerRow

            if step.isUser {
                userBubble
            } else {
                assistantOrSystemCard
            }
        }
        .frame(maxWidth: .infinity, alignment: step.isUser ? .trailing : .leading)
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            if step.isUser {
                Spacer()
            }

            Image(systemName: roleIcon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(roleColor)

            Text(roleLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("#\(step.stepIndex)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)

            if let model = step.model, !model.isEmpty, !step.isUser {
                Text("•")
                    .foregroundStyle(.tertiary)
                Text(model)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !step.isUser {
                Spacer()
            }

            if step.status.uppercased() != "DONE" && !step.status.isEmpty {
                PillBadge(text: step.status.uppercased(), tint: statusColor)
            }

            Text(step.createdAt, format: .dateTime.hour().minute().second())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private var userBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let content = step.content, !content.isEmpty {
                Text(UIFormatters.markdownAttributedString(content))
                    .font(.body)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
            }

            mediaSection
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [Color.indigo, Color.indigo.opacity(0.86)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .frame(maxWidth: 320, alignment: .trailing)
    }

    private var assistantOrSystemCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let thinking = step.thinking, !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DisclosureGroup(isExpanded: $showThinking) {
                    Text(thinking)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                } label: {
                    Label("Thinking Process (\(thinking.count) chars)", systemImage: "brain.head.profile")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.purple)
                }
                .padding(10)
                .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if let content = step.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(UIFormatters.markdownAttributedString(content))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !step.toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(step.toolCalls.enumerated()), id: \.offset) { idx, tool in
                        let key = "\(step.stepIndex)-\(idx)-\(tool.name)"
                        toolCallCard(tool: tool, key: key)
                    }
                }
            }

            mediaSection

            if step.isTruncated {
                HStack(spacing: 8) {
                    Image(systemName: "ellipsis.rectangle")
                        .foregroundStyle(.orange)
                    Text("Truncated: \(step.truncatedFields.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let onLoadFullTranscript {
                        Button("Load Full") {
                            onLoadFullTranscript()
                        }
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
                .padding(.top, 2)
            }

            if step.totalTokens > 0 {
                tokenFooter
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(borderTint, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func toolCallCard(tool: ToolCallItem, key: String) -> some View {
        let isExpanded = Binding<Bool>(
            get: { expandedToolIds.contains(key) },
            set: { newValue in
                if newValue {
                    expandedToolIds.insert(key)
                } else {
                    expandedToolIds.remove(key)
                }
            }
        )

        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.caption2)
                        .foregroundStyle(.cyan)
                    Text(tool.name)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                VStack(alignment: .trailing, spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(tool.prettyArgsJson)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Button {
                        UIFormatters.copyToPasteboard(tool.prettyArgsJson)
                    } label: {
                        Label("Copy JSON", systemImage: "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(10)
        .background(Color.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var mediaSection: some View {
        if !step.media.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(step.media) { item in
                    if item.isImage {
                        VStack(alignment: .leading, spacing: 4) {
                            AuthenticatedImageView(urlPath: item.urlPath, loadData: loadMediaData)
                                .frame(maxHeight: 260)
                            Text(item.filename)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Label(item.filename, systemImage: "paperclip")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
            }
        }
    }

    private var tokenFooter: some View {
        HStack(spacing: 10) {
            if let input = step.inputTokens, input > 0 {
                Label("In \(TokenFormatter.format(input))", systemImage: "arrow.down.circle")
            }
            if let cache = step.cacheReadTokens, cache > 0 {
                Label("Cache \(TokenFormatter.format(cache))", systemImage: "bolt.horizontal.circle")
                    .foregroundStyle(.green)
            }
            if let output = step.outputTokens, output > 0 {
                Label("Out \(TokenFormatter.format(output))", systemImage: "arrow.up.circle")
            }
            Spacer()
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private var roleIcon: String {
        if step.isUser { return "person.fill" }
        if step.isModel { return "sparkles" }
        return "gearshape.fill"
    }

    private var roleLabel: String {
        if step.isUser { return "You" }
        if step.isModel { return "Antigravity" }
        return step.source.capitalized
    }

    private var roleColor: Color {
        if step.isUser { return .indigo }
        if step.isModel { return .cyan }
        return .secondary
    }

    private var statusColor: Color {
        switch step.status.uppercased() {
        case "RUNNING": return .indigo
        case "ERROR", "FAILED": return .red
        case "WAITING": return .orange
        default: return .secondary
        }
    }

    private var borderTint: Color {
        if step.status.uppercased() == "ERROR" {
            return .red.opacity(0.4)
        }
        if step.isSystem {
            return .secondary.opacity(0.18)
        }
        return .primary.opacity(0.06)
    }

    private var cardBackground: Color {
        #if canImport(UIKit)
        step.isSystem
            ? Color(uiColor: .tertiarySystemGroupedBackground)
            : Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color.secondary.opacity(0.12)
        #endif
    }
}
