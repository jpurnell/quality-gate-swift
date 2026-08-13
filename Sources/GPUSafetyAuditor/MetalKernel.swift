import Foundation

/// Where a kernel's source text was found.
///
/// Both forms are required, and the distinction is not cosmetic. A codebase can
/// exclude its `.metal` files from every target — to keep the Metal toolchain off
/// the Playground build, say — and ship the shaders that actually run as Swift
/// string literals compiled with `makeLibrary(source:)`. Auditing only `.metal`
/// files there reports defects in code the compiler never sees, while missing every
/// kernel that executes.
public enum ShaderSource: Sendable, Equatable {

    /// A standalone `.metal` file. `excludedFromTarget` records that no target
    /// compiles it, which makes any finding inside it a statement about dead code.
    case metalFile(path: String, excludedFromTarget: Bool)

    /// Metal Shading Language embedded in a Swift string literal.
    case embedded(path: String, line: Int)

    /// The file the source lives in, whichever form it took.
    public var path: String {
        switch self {
        case .metalFile(let path, _): return path
        case .embedded(let path, _): return path
        }
    }

    /// The line the kernel begins on, when the form carries one.
    public var line: Int? {
        switch self {
        case .metalFile: return nil
        case .embedded(_, let line): return line
        }
    }
}

/// A kernel entry point recovered from either shader form.
public struct MetalKernel: Sendable, Equatable {

    /// The entry point's name.
    public let name: String

    /// The parameter carrying `[[thread_position_in_grid]]`, if the kernel takes one.
    ///
    /// A kernel without one cannot index per-thread and so cannot overrun.
    public let threadPositionParameter: String?

    /// Scalar parameters the thread id could be bounded against — `constant uint&`,
    /// `constant ulong&` and friends.
    ///
    /// This is the candidate set for a bound, not evidence that a bound is used.
    /// The difference is the whole of ``GPUSafetyAuditor``'s Rule 1: absence of any
    /// candidate proves the kernel cannot be correct; presence of one proves nothing.
    public let scalarParameters: [String]

    /// Pointer parameters in `device` or `constant` address space — the buffers a
    /// surplus thread would read or write past.
    public let bufferParameters: [String]

    /// The kernel body, brace to matching brace.
    public let body: String

    /// Where the kernel was found.
    public let source: ShaderSource

    /// The line the kernel's signature starts on, 1-based, within its own file.
    public let declarationLine: Int

    /// Creates a kernel record.
    public init(
        name: String,
        threadPositionParameter: String?,
        scalarParameters: [String],
        bufferParameters: [String],
        body: String,
        source: ShaderSource,
        declarationLine: Int
    ) {
        self.name = name
        self.threadPositionParameter = threadPositionParameter
        self.scalarParameters = scalarParameters
        self.bufferParameters = bufferParameters
        self.body = body
        self.source = source
        self.declarationLine = declarationLine
    }

    /// Whether the thread id is used to index a `device` or `constant` buffer.
    ///
    /// Indexing is what turns a surplus thread into a memory fault. A kernel that
    /// takes a thread id and never indexes with it — a reduction that only uses it
    /// for a barrier, for instance — is not this rule's business.
    public var indexesBufferWithThreadID: Bool {
        guard let id = threadPositionParameter, !bufferParameters.isEmpty else { return false }
        for buffer in bufferParameters where body.contains("\(buffer)[") {
            // The subscript must mention the thread id somewhere before its close.
            var searchRange = body.startIndex..<body.endIndex
            while let open = body.range(of: "\(buffer)[", range: searchRange) {
                if let close = body[open.upperBound...].firstIndex(of: "]") {
                    let subscriptText = body[open.upperBound..<close]
                    if subscriptText.containsIdentifier(id) { return true }
                    searchRange = body.index(after: close)..<body.endIndex
                } else {
                    searchRange = open.upperBound..<body.endIndex
                }
                if searchRange.isEmpty { break }
            }
        }
        return false
    }
}

extension StringProtocol {

    /// Whether `identifier` appears as a whole word, not as part of a longer name.
    ///
    /// `id` must not match inside `grid` or `width`; without this the rule reports
    /// kernels whose subscripts merely contain the letters of the thread parameter.
    func containsIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        var searchStart = startIndex
        while let found = range(of: identifier, range: searchStart..<endIndex) {
            let beforeOK: Bool
            if found.lowerBound == startIndex {
                beforeOK = true
            } else {
                let prev = self[index(before: found.lowerBound)]
                beforeOK = !(prev.isLetter || prev.isNumber || prev == "_")
            }
            let afterOK: Bool
            if found.upperBound == endIndex {
                afterOK = true
            } else {
                let next = self[found.upperBound]
                afterOK = !(next.isLetter || next.isNumber || next == "_")
            }
            if beforeOK && afterOK { return true }
            guard found.upperBound < endIndex else { return false }
            searchStart = index(after: found.lowerBound)
        }
        return false
    }
}
