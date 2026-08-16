import Foundation
import Testing
@testable import QualityGateCore

/// Tests for `TrapPolicy` and `TargetTypeMap` — whether a trap is a defect depends on who the
/// caller is.
///
/// Found by profiling `apple/swift-algorithms`, the survey's designated control: 57 files of
/// Apple-reviewed pure algorithms produced 89 errors, 73 of them traps inside `Collection`
/// conformances. `precondition(i != endIndex)` is not a defensive shortcut there — it is how
/// `Collection` is specified, and `Array` does the same.
///
/// Swift's Error Handling Rationale draws the line the language uses: `throws` for recoverable
/// errors, `precondition`/`fatalError` for *logic failures*. Whether that is appropriate
/// depends on the audience — an end user cannot act on a trap, a calling programmer can.
@Suite("TrapPolicy")
struct TrapPolicyTests {

    // MARK: - Target type resolution

    private let map = TargetTypeMap(targets: [
        .init(name: "MyLib", type: "library", path: "Sources/MyLib"),
        .init(name: "my-cli", type: "executable", path: "Sources/my-cli"),
        .init(name: "MyLibTests", type: "test", path: "Tests/MyLibTests"),
        .init(name: "MyPlugin", type: "plugin", path: "Plugins/MyPlugin"),
    ])

    @Test("a file resolves to its target's type")
    func resolvesByPath() {
        #expect(map.targetType(forFile: "Sources/MyLib/Chunked.swift") == .library)
        #expect(map.targetType(forFile: "Sources/my-cli/main.swift") == .executable)
        #expect(map.targetType(forFile: "Tests/MyLibTests/ChunkedTests.swift") == .test)
        #expect(map.targetType(forFile: "Plugins/MyPlugin/plugin.swift") == .plugin)
    }

    @Test("absolute paths resolve too")
    func resolvesAbsolutePaths() {
        #expect(map.targetType(forFile: "/Users/x/pkg/Sources/MyLib/Chunked.swift") == .library)
    }

    /// Fail strict, never lax. A file the map cannot place is treated as executable, so a
    /// resolution failure — a malformed `describe`, a path outside any target, a target type
    /// SwiftPM adds later — cannot silently relax the rule.
    @Test("an unresolvable file is treated as executable")
    func unresolvedIsStrict() {
        #expect(map.targetType(forFile: "Scripts/generate.swift") == .executable)
        #expect(TargetTypeMap(targets: []).targetType(forFile: "Sources/MyLib/X.swift") == .executable)
    }

    // MARK: - Verdicts by target type

    @Test("a trap in an executable is a finding")
    func executableTraps() {
        #expect(TrapPolicy.aggregate.verdict(targetType: .executable, message: nil) == .report)
    }

    /// The measured case. In a library the caller is another programmer with a stack trace, and
    /// the trap is the language's documented mechanism for telling them they misused the API.
    @Test("a trap in a library is counted, not reported")
    func libraryTraps() {
        #expect(TrapPolicy.aggregate.verdict(targetType: .library, message: nil) == .count)
    }

    /// A trap in a test *is* the failure mechanism, and the audience is the author standing
    /// right there. Decided 2026-08-16.
    @Test("a trap in a test is counted")
    func testTraps() {
        #expect(TrapPolicy.aggregate.verdict(targetType: .test, message: nil) == .count)
    }

    /// A build plugin's caller is SwiftPM; a trap surfaces as a build failure with a stack
    /// trace to the plugin author, never to an end user. Decided 2026-08-16.
    @Test("a trap in a plugin is counted, following library")
    func pluginTraps() {
        #expect(TrapPolicy.aggregate.verdict(targetType: .plugin, message: nil) == .count)
    }

    // MARK: - Unfinished work outranks the target

    /// The narrower rule that survives the relaxation, and is more defensible than the one it
    /// replaces. A trap saying "unimplemented" is not a contract — it is work that was not
    /// done, shipped where someone else's program will reach it.
    @Test("unfinished work is a finding in any target")
    func unfinishedWorkAlwaysReports() {
        for message in ["unimplemented", "TODO: handle this", "not implemented yet",
                        "FIXME", "unreachable"] {
            #expect(
                TrapPolicy.aggregate.verdict(targetType: .library, message: message) == .report,
                "expected \(message) to report")
        }
    }

    /// The guard on that rule: a legitimate contract message must not be caught by it.
    @Test("a contract message is not unfinished work")
    func contractMessagesAreNotUnfinished() {
        for message in ["Can't advance past endIndex", "Index out of bounds",
                        "Windows size must be greater than zero"] {
            #expect(
                TrapPolicy.aggregate.verdict(targetType: .library, message: message) == .count,
                "expected \(message) to be counted")
        }
    }

    // MARK: - Policies

    @Test("forbidden reports everywhere — today's behaviour stays reachable")
    func forbiddenReportsEverywhere() {
        for type in TargetType.allCases {
            #expect(TrapPolicy.forbidden.verdict(targetType: type, message: nil) == .report)
        }
    }

    /// Right for a codebase that chooses it, wrong to impose on a survey: demanding a
    /// justification at 73 sites is the wall that gets a checker excluded.
    @Test("justified asks for a justification in library-like targets")
    func justifiedRequiresJustification() {
        #expect(TrapPolicy.justified.verdict(targetType: .library, message: nil) == .requireJustification)
        #expect(TrapPolicy.justified.verdict(targetType: .test, message: nil) == .requireJustification)
        // An executable is still a hard finding — justification does not soften it.
        #expect(TrapPolicy.justified.verdict(targetType: .executable, message: nil) == .report)
    }

    @Test("aggregate is the default")
    func aggregateIsDefault() {
        #expect(TrapPolicy.default == .aggregate)
    }
}
