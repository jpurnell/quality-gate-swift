// NarrativeMarkdown.swift
// IJSDashboardUI
//
// The institutional narrative is authored in Markdown (## headers, --- rules,
// **inline** styling). SwiftGUIKit's `.paragraph` node renders plain body text on
// every surface, so proper block rendering is a native-surface enhancement here.
// The block parser is a pure function, unit-tested independently of the view.

#if canImport(SwiftUI)
import SwiftUI

/// A block element parsed from narrative Markdown.
enum NarrativeBlock: Equatable {
    /// A heading with its `#` level (1 = top).
    case heading(level: Int, text: String)
    /// A thematic break (`---`).
    case rule
    /// A body paragraph (soft-wrapped lines joined).
    case paragraph(String)
}

/// A minimal block-level Markdown splitter — headings, thematic breaks, and
/// paragraphs. Inline styling (bold/italic/code) is left to `AttributedString`
/// at render time.
enum NarrativeMarkdown {

    /// Splits narrative Markdown into block elements.
    static func blocks(from markdown: String) -> [NarrativeBlock] {
        var result: [NarrativeBlock] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            let joined = paragraphLines.joined(separator: " ")
            if !joined.isEmpty { result.append(.paragraph(joined)) }
            paragraphLines = []
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
            } else if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                result.append(.rule)
            } else if line.hasPrefix("#") {
                flushParagraph()
                let level = line.prefix { $0 == "#" }.count
                let text = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                result.append(.heading(level: level, text: text))
            } else {
                paragraphLines.append(line)
            }
        }
        flushParagraph()
        return result
    }
}

/// Renders narrative Markdown as native SwiftUI: headers emphasized, rules as
/// dividers, paragraphs with inline styling and selectable text.
struct NarrativeMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(NarrativeMarkdown.blocks(from: markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(level, text):
                    Text(text)
                        .font(level <= 1 ? .title3.bold() : .headline)
                        .padding(.top, 4)
                case .rule:
                    Divider()
                case let .paragraph(text):
                    Text(inlineAttributed(text))
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Parses inline Markdown (bold/italic/code), falling back to plain text.
    private func inlineAttributed(_ text: String) -> AttributedString {
        // silent: malformed inline markdown falls back to the plain string
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
#endif
