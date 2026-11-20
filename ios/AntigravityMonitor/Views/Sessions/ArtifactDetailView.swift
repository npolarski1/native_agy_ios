import AntigravityCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct ArtifactListView: View {
    let sessionId: String
    let artifacts: [ArtifactItem]
    let isLoading: Bool
    let loadText: @MainActor (String, String) async throws -> ArtifactContentResponse
    let loadBinary: @MainActor (String, String) async -> Data?

    var body: some View {
        if isLoading && artifacts.isEmpty {
            ProgressView("Loading artifacts...")
                .frame(maxWidth: .infinity, minHeight: 200)
        } else if artifacts.isEmpty {
            ContentUnavailableView {
                Label("No Artifacts Yet", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Markdown plans, reports, and captured screenshots generated in this session appear here.")
            }
            .padding(.top, 32)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(artifacts) { artifact in
                    NavigationLink {
                        ArtifactDetailView(
                            sessionId: sessionId,
                            artifact: artifact,
                            loadText: loadText,
                            loadBinary: loadBinary
                        )
                    } label: {
                        ArtifactRowCard(artifact: artifact)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}

private struct ArtifactRowCard: View {
    let artifact: ArtifactItem

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: iconName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(artifact.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(artifact.formattedSize)
                    Text("•")
                    Text(artifact.updatedAt, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var iconName: String {
        if artifact.isImage { return "photo.fill" }
        if artifact.isMarkdown { return "doc.richtext.fill" }
        return "doc.text.fill"
    }

    private var iconColor: Color {
        if artifact.isImage { return .pink }
        if artifact.isMarkdown { return .indigo }
        return .cyan
    }

    private var cardBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color.secondary.opacity(0.12)
        #endif
    }
}

struct ArtifactDetailView: View {
    let sessionId: String
    let artifact: ArtifactItem
    let loadText: @MainActor (String, String) async throws -> ArtifactContentResponse
    let loadBinary: @MainActor (String, String) async -> Data?

    @State private var textContent: String?
    @State private var imageData: Data?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showRawSource = false
    @State private var copiedToast = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                metadataHeader

                if isLoading {
                    ProgressView("Fetching artifact...")
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Failed to Load Artifact", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    }
                } else if artifact.isImage {
                    imageContentView
                } else if let textContent {
                    if artifact.isMarkdown && !showRawSource {
                        MarkdownBlockRenderer(markdown: textContent)
                    } else {
                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(textContent)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .padding()
        }
        .navigationTitle(artifact.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !artifact.isImage && artifact.isMarkdown {
                    Button {
                        showRawSource.toggle()
                    } label: {
                        Image(systemName: showRawSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityLabel(showRawSource ? "Show Rendered Markdown" : "Show Raw Source")
                }

                if let textContent {
                    Button {
                        UIFormatters.copyToPasteboard(textContent)
                        copiedToast = true
                    } label: {
                        Image(systemName: copiedToast ? "checkmark" : "doc.on.doc")
                    }
                }
            }
        }
        .task(id: artifact.relativePath) {
            await loadArtifact()
        }
    }

    private var metadataHeader: some View {
        HStack(spacing: 10) {
            PillBadge(text: artifact.mimeType, tint: .indigo)
            PillBadge(text: artifact.formattedSize, tint: .secondary)
            Spacer()
            Text(artifact.updatedAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var imageContentView: some View {
        #if canImport(UIKit)
        if let imageData, let uiImage = UIImage(data: imageData) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        } else {
            ContentUnavailableView("Unable to Decode Image", systemImage: "photo.badge.exclamationmark")
        }
        #else
        ContentUnavailableView("Image preview unavailable", systemImage: "photo")
        #endif
    }

    private var cardBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color.secondary.opacity(0.12)
        #endif
    }

    private func loadArtifact() async {
        isLoading = true
        errorMessage = nil
        if artifact.isImage {
            imageData = await loadBinary(sessionId, artifact.relativePath)
            if imageData == nil {
                errorMessage = "Could not download image data from the bridge."
            }
        } else {
            do {
                let response = try await loadText(sessionId, artifact.relativePath)
                textContent = response.content
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }
}

/// Lightweight block-level Markdown renderer supporting headings, fenced code blocks, lists, and inline styles.
private struct MarkdownBlockRenderer: View {
    let markdown: String

    private enum Block: Identifiable {
        case heading(id: Int, level: Int, text: String)
        case code(id: Int, language: String, code: String)
        case bullet(id: Int, text: String)
        case paragraph(id: Int, text: String)

        var id: Int {
            switch self {
            case .heading(let id, _, _): return id
            case .code(let id, _, _): return id
            case .bullet(let id, _): return id
            case .paragraph(let id, _): return id
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(parseBlocks(markdown)) { block in
                switch block {
                case .heading(_, let level, let text):
                    Text(UIFormatters.markdownAttributedString(text))
                        .font(headingFont(for: level))
                        .padding(.top, level == 1 ? 6 : 4)
                        .textSelection(.enabled)

                case .code(_, let language, let code):
                    VStack(alignment: .leading, spacing: 6) {
                        if !language.isEmpty {
                            Text(language.uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(code)
                                .font(.caption.monospaced())
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                    .background(codeBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                case .bullet(_, let text):
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.indigo)
                        Text(UIFormatters.markdownAttributedString(text))
                            .font(.subheadline)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                case .paragraph(_, let text):
                    Text(UIFormatters.markdownAttributedString(text))
                        .font(.subheadline)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.bold)
        case 2: return .title3.weight(.bold)
        default: return .headline
        }
    }

    private var codeBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color.secondary.opacity(0.14)
        #endif
    }

    private func parseBlocks(_ source: String) -> [Block] {
        var blocks: [Block] = []
        let lines = source.components(separatedBy: .newlines)
        var index = 0
        var nextId = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.code(id: nextId, language: lang, code: codeLines.joined(separator: "\n")))
                nextId += 1
                index += 1
                continue
            }

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if trimmed.hasPrefix("### ") {
                blocks.append(.heading(id: nextId, level: 3, text: String(trimmed.dropFirst(4))))
                nextId += 1
            } else if trimmed.hasPrefix("## ") {
                blocks.append(.heading(id: nextId, level: 2, text: String(trimmed.dropFirst(3))))
                nextId += 1
            } else if trimmed.hasPrefix("# ") {
                blocks.append(.heading(id: nextId, level: 1, text: String(trimmed.dropFirst(2))))
                nextId += 1
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                blocks.append(.bullet(id: nextId, text: String(trimmed.dropFirst(2))))
                nextId += 1
            } else {
                var paragraphLines = [trimmed]
                while index + 1 < lines.count {
                    let peek = lines[index + 1].trimmingCharacters(in: .whitespaces)
                    if peek.isEmpty || peek.hasPrefix("#") || peek.hasPrefix("```") || peek.hasPrefix("- ") || peek.hasPrefix("* ") {
                        break
                    }
                    index += 1
                    paragraphLines.append(peek)
                }
                blocks.append(.paragraph(id: nextId, text: paragraphLines.joined(separator: " ")))
                nextId += 1
            }
            index += 1
        }
        return blocks
    }
}
