// NarrativeMarkdown.swift
// IJSDashboardUI
//
// The institutional narrative is authored in Markdown (## headers, --- rules,
// pipe tables, **inline** styling). SwiftGUIKit's `.paragraph` node renders plain
// body text on every surface, so proper block rendering is a native-surface
// enhancement here. The block parser is a pure function, unit-tested apart from
// the view.

#if canImport(SwiftUI)
import SwiftUI

/// A block element parsed from narrative Markdown.
enum NarrativeBlock: Equatable {
    /// A heading with its `#` level (1 = top).
    case heading(level: Int, text: String)
    /// A thematic break (`---`).
    case rule
    /// A pipe table: a header row and zero or more data rows.
    case table(headers: [String], rows: [[String]])
    /// A body paragraph (soft-wrapped lines joined).
    case paragraph(String)
}

/// A minimal block-level Markdown splitter — headings, thematic breaks, pipe
/// tables, and paragraphs. Inline styling (bold/italic/code) is left to
/// `AttributedString` at render time.
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

        let lines = markdown.lines
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                index += 1
            } else if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                result.append(.rule)
                index += 1
            } else if line.hasPrefix("#") {
                flushParagraph()
                let level = line.prefix { $0 == "#" }.count
                let text = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                result.append(.heading(level: level, text: text))
                index += 1
            } else if line.hasPrefix("|") {
                flushParagraph()
                var tableLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix("|") else { break }
                    tableLines.append(candidate)
                    index += 1
                }
                if let table = parseTable(tableLines) { result.append(table) }
            } else {
                paragraphLines.append(line)
                index += 1
            }
        }
        flushParagraph()
        return result
    }

    /// Builds a table block from consecutive pipe lines, skipping the `|---|`
    /// separator row when present.
    static func parseTable(_ lines: [String]) -> NarrativeBlock? {
        guard let first = lines.first else { return nil }
        let headers = parseCells(first)
        var dataStart = 1
        if lines.count > 1, isSeparatorRow(parseCells(lines[1])) { dataStart = 2 }
        let rows = lines.count > dataStart ? lines[dataStart...].map(parseCells) : []
        return .table(headers: headers, rows: Array(rows))
    }

    /// Splits a `| a | b |` line into trimmed cells, dropping the empty ends.
    static func parseCells(_ line: String) -> [String] {
        var cells = line
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }

    /// Whether a row is a Markdown table separator (all cells like `---` / `:--:`).
    static func isSeparatorRow(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }
}

/// Renders narrative Markdown as native SwiftUI: headers emphasized, rules as
/// dividers, pipe tables as aligned grids, paragraphs with inline styling.
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
                case let .table(headers, rows):
                    VStack(alignment: .leading, spacing: 2) {
                        tableRow(headers, isHeader: true)
                        Divider()
                        ForEach(rows.indices, id: \.self) { tableRow(rows[$0], isHeader: false) }
                    }
                    .padding(.vertical, 4)
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

    @ViewBuilder
    private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(cells.indices, id: \.self) { c in
                Text(inlineAttributed(cells[c]))
                    .font(.body)
                    .fontWeight(isHeader ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Parses inline Markdown (bold/italic/code), falling back to plain text.
    private func inlineAttributed(_ text: String) -> AttributedString {
        // silent: malformed inline markdown falls back to the plain string
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
#endif
