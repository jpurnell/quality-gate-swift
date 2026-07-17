import Foundation
import QualityGateCore
import SwiftParser
import SwiftSyntax

// MARK: - Normalized tokens

/// One token of a normalized token stream: identifier/literal-erased text
/// plus the 1-based source line its content starts on.
struct NormalizedToken: Sendable, Equatable {
    /// Normalized token text: `ID` for identifiers, `LIT` for string/numeric
    /// literal content, otherwise the verbatim token text.
    let text: String
    /// 1-based line of the token's start position (after leading trivia).
    let line: Int
}

/// Produces normalized token streams for clone detection.
///
/// Trivia (whitespace and comments) is dropped by construction: only token
/// text participates. Identifiers normalize to `ID` so renamed-identifier
/// clones still hash identically; keywords, punctuation, operators, **and
/// literal content stay verbatim**. Keeping literals verbatim is deliberate: it
/// is what distinguishes a genuine copy-paste (which preserves its literals)
/// from two structurally-parallel-but-distinct blocks (e.g. two tests that
/// share Swift's assertion grammar but feed entirely different data). Collapsing
/// literals to a single `LIT` sentinel made those isomorphic-but-unrelated
/// blocks collide, which was the dominant source of false-positive clones.
enum CloneTokenizer {

    /// Tokenizes Swift source into a normalized token stream.
    ///
    /// - Parameter source: Swift source text.
    /// - Returns: Normalized tokens in source order, end-of-file excluded.
    static func tokenize(source: String) -> [NormalizedToken] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: "", tree: tree)
        var tokens: [NormalizedToken] = []
        for token in tree.tokens(viewMode: .sourceAccurate) {
            let text: String
            switch token.tokenKind {
            case .endOfFile:
                continue
            case .identifier, .dollarIdentifier:
                text = "ID"
            default:
                // Literals and everything else keep their verbatim text so that
                // blocks differing only in their data no longer hash alike.
                text = token.text
            }
            let line = converter.location(for: token.positionAfterSkippingLeadingTrivia).line
            tokens.append(NormalizedToken(text: text, line: line))
        }
        return tokens
    }
}

// MARK: - Deterministic hashing

/// 64-bit FNV-1a hash. Deterministic across processes and runs, unlike
/// `Hasher`/`String.hashValue`, which are per-process seeded.
struct FNV1a: Sendable {
    /// The current hash value (FNV-1a offset basis before any input).
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    /// Folds one byte into the hash.
    mutating func combine(byte: UInt8) {
        value ^= UInt64(byte)
        value = value &* 0x0000_0100_0000_01b3
    }

    /// Folds a string's UTF-8 bytes plus a unit separator into the hash.
    /// The separator keeps token boundaries unambiguous (`ab`+`c` ≠ `a`+`bc`).
    mutating func combine(_ string: String) {
        for byte in string.utf8 {
            combine(byte: byte)
        }
        combine(byte: 0x1F)
    }

    /// Folds a 64-bit value into the hash in little-endian byte order.
    mutating func combine(_ other: UInt64) {
        var remaining = other
        for _ in 0..<8 {
            combine(byte: UInt8(truncatingIfNeeded: remaining))
            remaining >>= 8
        }
    }
}

// MARK: - File token streams

/// A tokenized source file ready for window hashing.
struct FileTokenStream: Sendable {
    /// Absolute path used in emitted diagnostics.
    let absolutePath: String
    /// Root-relative path (e.g. `Sources/Foo.swift`) used in messages.
    let relativePath: String
    /// The file's normalized token stream.
    let tokens: [NormalizedToken]
    /// Per-token FNV-1a hash of the normalized text, precomputed once.
    let tokenHashes: [UInt64]

    /// Creates a stream, precomputing per-token hashes.
    init(absolutePath: String, relativePath: String, tokens: [NormalizedToken]) {
        self.absolutePath = absolutePath
        self.relativePath = relativePath
        self.tokens = tokens
        self.tokenHashes = tokens.map { token in
            var hasher = FNV1a()
            hasher.combine(token.text)
            return hasher.value
        }
    }

    /// The 1-based line span covered by `count` tokens starting at `start`,
    /// or `nil` when the range is out of bounds.
    func lineSpan(start: Int, count: Int) -> (startLine: Int, endLine: Int)? {
        guard start >= 0, count > 0, start + count <= tokens.count else { return nil }
        return (tokens[start].line, tokens[start + count - 1].line)
    }
}

// MARK: - Clone detection

/// One maximal clone block pair. Sides are canonically ordered: `fileA` sorts
/// before `fileB` (or, within one file, `startA < startB`), and the blocks
/// never overlap each other.
struct ClonePair: Sendable, Equatable {
    /// Index of the first file in the detector's (sorted) file list.
    let fileA: Int
    /// Token index where the first block starts.
    let startA: Int
    /// Index of the second file.
    let fileB: Int
    /// Token index where the second block starts.
    let startB: Int
    /// Number of normalized tokens in each block of the pair.
    let tokenCount: Int
}

/// Sliding-window clone detection over normalized token streams.
enum CloneDetector {

    /// FNV-1a hashes of every `window`-token sliding window (step 1).
    ///
    /// - Returns: One hash per window start; empty when the file is shorter
    ///   than `window` tokens.
    static func windowHashes(for file: FileTokenStream, window: Int) -> [UInt64] {
        let size = max(1, window)
        guard file.tokenHashes.count >= size else { return [] }
        var hashes: [UInt64] = []
        hashes.reserveCapacity(file.tokenHashes.count - size + 1)
        for start in 0...(file.tokenHashes.count - size) {
            var hasher = FNV1a()
            for offset in 0..<size {
                hasher.combine(file.tokenHashes[start + offset])
            }
            hashes.append(hasher.value)
        }
        return hashes
    }

    /// Detects maximal clone block pairs across the given files.
    ///
    /// Seed windows sharing a hash are grouped by (fileA, fileB, alignment
    /// offset); contiguous seed runs merge into one maximal block per pair.
    /// Same-file pairs whose blocks overlap are discarded, and symmetric
    /// duplicates never arise because occurrences are canonically ordered.
    ///
    /// - Parameters:
    ///   - files: Tokenized files, already sorted by path for determinism.
    ///   - minTokens: The sliding-window size (minimum reportable clone).
    /// - Returns: Clone pairs sorted by (fileA, startA, fileB, startB).
    static func detectPairs(files: [FileTokenStream], minTokens: Int) -> [ClonePair] {
        let window = max(1, minTokens)

        var occurrences: [UInt64: [(file: Int, start: Int)]] = [:]
        for (fileIndex, file) in files.enumerated() {
            for (start, hash) in windowHashes(for: file, window: window).enumerated() {
                occurrences[hash, default: []].append((fileIndex, start))
            }
        }

        struct GroupKey: Hashable {
            let fileA: Int
            let fileB: Int
            let delta: Int
        }

        // Occurrence lists are built in (file, start) ascending order, so
        // every generated pair is already canonical.
        var groups: [GroupKey: Set<Int>] = [:]
        for list in occurrences.values where list.count >= 2 {
            for i in 0..<(list.count - 1) {
                for j in (i + 1)..<list.count {
                    let a = list[i]
                    let b = list[j]
                    let key = GroupKey(fileA: a.file, fileB: b.file, delta: b.start - a.start)
                    groups[key, default: []].insert(a.start)
                }
            }
        }

        var pairs: [ClonePair] = []
        for (key, startSet) in groups {
            let starts = startSet.sorted()
            var index = 0
            while index < starts.count {
                let runBegin = starts[index]
                var runEnd = runBegin
                while index + 1 < starts.count, starts[index + 1] == runEnd + 1 {
                    index += 1
                    runEnd = starts[index]
                }
                index += 1
                let tokenCount = runEnd - runBegin + window
                let startA = runBegin
                let startB = runBegin + key.delta
                // A block must not overlap its partner (same-file self-match).
                if key.fileA == key.fileB, startB < startA + tokenCount { continue }
                pairs.append(ClonePair(
                    fileA: key.fileA,
                    startA: startA,
                    fileB: key.fileB,
                    startB: startB,
                    tokenCount: tokenCount
                ))
            }
        }

        return pairs.sorted { lhs, rhs in
            if lhs.fileA != rhs.fileA { return lhs.fileA < rhs.fileA }
            if lhs.startA != rhs.startA { return lhs.startA < rhs.startA }
            if lhs.fileB != rhs.fileB { return lhs.fileB < rhs.fileB }
            if lhs.startB != rhs.startB { return lhs.startB < rhs.startB }
            return lhs.tokenCount < rhs.tokenCount
        }
    }

    /// One member block of a clone class: a maximal duplicated span in one file.
    struct ClassBlock: Sendable, Equatable, Hashable {
        /// Index of the file in the detector's (sorted) file list.
        let file: Int
        /// Token index where the block starts.
        let start: Int
        /// Number of normalized tokens in the block.
        let tokenCount: Int
    }

    /// A set of two-or-more maximal blocks that share an identical normalized
    /// token sequence. Reporting one class per group — instead of one row per
    /// pairwise match — collapses an N-way shared block from `N·(N−1)/2` rows to
    /// a single finding.
    struct CloneClass: Sendable, Equatable {
        /// Number of normalized tokens in each member block.
        let tokenCount: Int
        /// Member blocks, sorted by `(file, start)`; always at least two.
        let blocks: [ClassBlock]
    }

    /// Groups clone pairs into clone classes by identical normalized content.
    ///
    /// Every pair contributes both of its maximal blocks; blocks whose token
    /// sequence hashes identically (same content and length) collapse into one
    /// class. Overlapping maximal blocks of *different* lengths remain distinct
    /// classes, which is correct — they are clones of different extents.
    ///
    /// - Parameters:
    ///   - files: Tokenized files, already sorted by path for determinism.
    ///   - minTokens: The sliding-window size (minimum reportable clone).
    /// - Returns: Clone classes sorted by `(anchor file, anchor start, tokenCount)`.
    static func detectClasses(files: [FileTokenStream], minTokens: Int) -> [CloneClass] {
        let pairs = detectPairs(files: files, minTokens: minTokens)

        // Signature of a block: FNV-1a fold over its per-token hashes. Same
        // signature ⇒ same normalized token sequence (and, implicitly, length).
        func signature(file: Int, start: Int, count: Int) -> UInt64 {
            var hasher = FNV1a()
            let hashes = files[file].tokenHashes
            for offset in 0..<count where start + offset < hashes.count {
                hasher.combine(hashes[start + offset])
            }
            return hasher.value
        }

        var groups: [UInt64: Set<ClassBlock>] = [:]
        for pair in pairs {
            for block in [
                ClassBlock(file: pair.fileA, start: pair.startA, tokenCount: pair.tokenCount),
                ClassBlock(file: pair.fileB, start: pair.startB, tokenCount: pair.tokenCount),
            ] {
                let sig = signature(file: block.file, start: block.start, count: block.tokenCount)
                groups[sig, default: []].insert(block)
            }
        }

        var classes: [CloneClass] = []
        for blockSet in groups.values where blockSet.count >= 2 {
            let sorted = blockSet.sorted { lhs, rhs in
                if lhs.file != rhs.file { return lhs.file < rhs.file }
                return lhs.start < rhs.start
            }
            guard let tokenCount = sorted.first?.tokenCount else { continue }
            classes.append(CloneClass(tokenCount: tokenCount, blocks: sorted))
        }

        return classes.sorted { lhs, rhs in
            guard let a = lhs.blocks.first, let b = rhs.blocks.first else { return false }
            if a.file != b.file { return a.file < b.file }
            if a.start != b.start { return a.start < b.start }
            return lhs.tokenCount < rhs.tokenCount
        }
    }

    /// Robust-winnowing selection over a window-hash sequence.
    ///
    /// From every run of `winnowWindow` consecutive window hashes, the
    /// rightmost minimum is selected. Any duplicate span of at least
    /// `window + winnowWindow - 1` tokens shared with another project is
    /// guaranteed to contribute at least one common fingerprint — the
    /// standard MOSS guarantee — while keeping the emitted set sparse.
    ///
    /// - Returns: Sorted, distinct window-start indices.
    static func winnowedIndices(of hashes: [UInt64], winnowWindow: Int) -> [Int] {
        guard !hashes.isEmpty else { return [] }
        let size = max(1, winnowWindow)
        guard hashes.count > size else {
            return [rightmostMinIndex(of: hashes, in: 0..<hashes.count)]
        }
        var selected: Set<Int> = []
        for start in 0...(hashes.count - size) {
            selected.insert(rightmostMinIndex(of: hashes, in: start..<(start + size)))
        }
        return selected.sorted()
    }

    /// Index of the rightmost minimum hash within `range`. The range must be
    /// non-empty and within bounds; the range's lower bound is the fallback.
    private static func rightmostMinIndex(of hashes: [UInt64], in range: Range<Int>) -> Int {
        var bestIndex = range.lowerBound
        var bestValue = UInt64.max
        for index in range where index < hashes.count {
            if hashes[index] <= bestValue {
                bestValue = hashes[index]
                bestIndex = index
            }
        }
        return bestIndex
    }
}
