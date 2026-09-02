import Foundation
import Testing
@testable import PointerEscapeAuditor
@testable import QualityGateCore

/// What the *return* path asks about a with-block's value.
///
/// `return read(into: raw)` returns an `Int`. Reporting `return-from-with-block` because the
/// expression *mentions* `raw` answers the wrong question: the rule is about what leaves the
/// block, and what leaves is the count.
///
/// This is narrower than it may look, and deliberately so. Passing a pointer into a function
/// whose contract is unknown is still flagged — by `passed-as-inout`'s conservative fallback,
/// which exists because that function may store what it is handed. The sanctioned answer there
/// is `allowedEscapeFunctions`, an explicit statement that a named function borrows rather than
/// keeps. Nothing here weakens that; the two rules simply stop answering the same question
/// twice, once correctly and once by accident.
@Suite("PointerEscapeAuditor: borrowed arguments")
struct BorrowedArgumentTests {

    private func pointerEscapes(_ result: CheckResult) -> [Diagnostic] {
        result.diagnostics.filter { $0.ruleId?.hasPrefix("pointer-escape") == true }
    }

    @Test("A call returning a count is not an escape because it took the pointer")
    func borrowedArgumentIsNotAnEscape() async throws {
        let code = """
        func readInto(_ buffer: UnsafeMutableRawBufferPointer) throws -> Int { 0 }
        func read(into bytes: inout [UInt8]) throws -> Int {
            return try bytes.withUnsafeMutableBytes { raw in
                try readInto(raw)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(pointerEscapes(result).isEmpty, "an Int left the block, not a pointer")
    }

    /// The same shape, and the reason the fix is narrow: handing the pointer to a function
    /// whose contract is unknown is still reported, because that function may keep it. What
    /// changed is only *which* rule says so — the conservative fallback, whose answer is to
    /// allowlist the function once you know it borrows.
    @Test("An unknown function receiving the pointer is still reported, by the right rule")
    func unknownFunctionStillReported() async throws {
        let code = """
        func write(fd: Int, from buffer: UnsafeRawBufferPointer, count: Int) -> Int { 0 }
        func send(_ data: [UInt8]) -> Int {
            return data.withUnsafeBytes { raw in
                write(fd: 1, from: raw, count: raw.count)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        let rules = Set(pointerEscapes(result).compactMap(\.ruleId))
        #expect(
            !rules.contains("pointer-escape.return-from-with-block"),
            "an Int left the block, not a pointer")
        #expect(
            rules.contains("pointer-escape.passed-as-inout"),
            "the conservative fallback still covers a function whose contract is unknown")
    }

    /// And allowlisting it clears the report entirely, which is the sanctioned way to say a
    /// function borrows rather than keeps.
    @Test("Allowlisting the borrowing function clears it")
    func allowlistedBorrowingFunctionIsClean() async throws {
        let code = """
        func write(fd: Int, from buffer: UnsafeRawBufferPointer, count: Int) -> Int { 0 }
        func send(_ data: [UInt8]) -> Int {
            return data.withUnsafeBytes { raw in
                write(fd: 1, from: raw, count: raw.count)
            }
        }
        """
        let result = try await TestHelpers.audit(code, allowedEscapeFunctions: ["write"])
        #expect(pointerEscapes(result).isEmpty)
    }

    // MARK: - What must still be caught

    /// The distinction this rests on: a call that *constructs a pointer* from the tracked one
    /// returns a pointer, and that does leave the block.
    @Test("Constructing a pointer from the tracked one is still an escape")
    func constructingAPointerIsStillAnEscape() async throws {
        let code = """
        func use(_ bytes: inout [UInt8]) -> UnsafeMutableRawBufferPointer {
            return bytes.withUnsafeMutableBufferPointer { pointer in
                UnsafeMutableRawBufferPointer(pointer)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!pointerEscapes(result).isEmpty, "a pointer was built from it and returned")
    }

    /// An initializer is treated as keeping what it is handed, and the two `Data` initializers
    /// are why it has to be.
    ///
    /// `Data(bytesNoCopy:count:deallocator:)` keeps pointing at the block's memory after the
    /// block returns. `Data(_:)` copies. They differ by one argument label, and a caller can
    /// write either — so a checker reading syntax alone cannot separate them, and the reading
    /// that is wrong-but-safe is the one that flags both. `allowedEscapeFunctions` is how a
    /// caller says which of the two this is.
    @Test("Both Data initializers are flagged, because syntax cannot tell them apart")
    func initializersAreTreatedAsKeeping() async throws {
        let escaping = """
        import Foundation
        func leak(_ bytes: inout [UInt8]) -> Data {
            return bytes.withUnsafeMutableBytes { raw in
                Data(bytesNoCopy: raw.baseAddress!, count: raw.count, deallocator: .none)
            }
        }
        """
        #expect(!pointerEscapes(try await TestHelpers.audit(escaping)).isEmpty)

        let copying = """
        import Foundation
        func copy(_ bytes: [UInt8]) -> Data {
            return bytes.withUnsafeBytes { raw in
                Data(raw)
            }
        }
        """
        #expect(
            !pointerEscapes(try await TestHelpers.audit(copying)).isEmpty,
            "conservative, and unchanged from before: an initializer may store what it is given")
    }

    /// Returning the pointer itself, or a member of it, is unchanged.
    @Test("Returning the pointer or its base address is still an escape", arguments: [
        "raw", "raw.baseAddress", "raw.advanced(by: 1)",
    ])
    func returningThePointerIsStillAnEscape(expression: String) async throws {
        let code = """
        func use(_ bytes: [UInt8]) -> Any {
            return bytes.withUnsafeBytes { raw in
                \(expression)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!pointerEscapes(result).isEmpty, "\(expression) carries the pointer out")
    }

    /// Appending into a collection outside the block is a different rule and must not be
    /// weakened by this: there the pointer *is* the argument being stored.
    @Test("Appending the pointer to an outer collection is still an escape")
    func appendingIsStillAnEscape() async throws {
        let code = """
        var saved: [UnsafeRawBufferPointer] = []
        func use(_ bytes: [UInt8]) {
            bytes.withUnsafeBytes { raw in
                saved.append(raw)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!pointerEscapes(result).isEmpty)
    }
}
