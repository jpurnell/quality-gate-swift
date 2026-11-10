import Foundation

/// Glob matching over project-relative paths, for the exemption lists in `designTokens`.
///
/// `**` as a whole segment matches any number of segments (including none); `*` and `?` match
/// within one segment and never across a `/`. A pattern that is fully consumed with path
/// segments left over still matches, so a pattern naming a directory covers everything beneath it.
///
/// Matching is an iterative table over segments rather than a recursive descent: a pattern such as
/// `**/a/**/b` would otherwise branch on every `**`.
enum PathGlob {

    /// Whether `pattern` covers the project-relative `path`.
    static func matches(_ pattern: String, path: String) -> Bool {
        let patternSegments = segments(pattern)
        let pathSegments = segments(path)
        guard !patternSegments.isEmpty else { return false }

        let patternCount = patternSegments.count
        let pathCount = pathSegments.count
        // reach[i][j]: the first i pattern segments match exactly the first j path segments.
        var reach = Array(repeating: Array(repeating: false, count: pathCount + 1), count: patternCount + 1)
        reach[0][0] = true
        for i in 1...patternCount {
            let segment = patternSegments[i - 1]
            for j in 0...pathCount {
                if segment == "**" {
                    // Zero segments, or one more than the shortest reach so far.
                    reach[i][j] = reach[i - 1][j] || (j > 0 && reach[i][j - 1])
                } else if j > 0, reach[i - 1][j - 1], segmentMatches(segment, pathSegments[j - 1]) {
                    reach[i][j] = true
                }
            }
        }
        // Fully consumed pattern with segments left over is a directory prefix.
        return reach[patternCount].contains(true)
    }

    private static func segments(_ value: String) -> [String] {
        var text = value
        while text.hasPrefix("./") { text.removeFirst(2) }
        return text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// `*` and `?` over the characters of one segment.
    private static func segmentMatches(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern)
        let t = Array(text)
        var pi = 0
        var ti = 0
        var starIndex: Int?
        var matchIndex = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                starIndex = pi
                matchIndex = ti
                pi += 1
            } else if let star = starIndex {
                pi = star + 1
                matchIndex += 1
                ti = matchIndex
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
