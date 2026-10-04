import Foundation
import Testing
import QualityGateCore
@testable import BuildChecker

/// Byte-level tests of the `.dia` reader.
///
/// Both fixtures are real: `Warns.dia` and `Clean.dia` as Swift 6.4 wrote them for a two-file
/// package built at `/private/tmp/qg-dia-fixture/Fixture`, embedded as base64 so the test needs
/// no toolchain. `Warns.swift` drops the result of `loud()` at line 6, column 9.
/// See `quality-gate-swift-project/plans/proposals/AWarmBuildForgetsItsWarnings.md` §5, 18–20.
@Suite("SerializedDiagnosticsReader")
struct SerializedDiagnosticsReaderTests {

    /// `Warns.dia`: 600 bytes, one warning.
    static let warnsBase64 = """
        RElBRwEIAAA8AAAABwGyQLRCOdBDODwggS2UgzzMQzq8gzscBIhigEBxECQLBCmkQzicw0MikEI6hMM5pII7mMM7PCTDLMjDOMhC
        OLjDOZTDA1KMQjjQgyuEQzuUw0NCkEI6hMM5mAI7hMM5PCSGKaQDO5SDK4RDO5TDg3GYQjrgQyrQw8OEzMI71IM8jEM5mEI6sEM5
        jMI7uAM9lIM70MM8HASJqoAMKgKFQCFQiBIlMKhkgcAgSE0HqAgUAoVAQUWgECgECkkCUQKDahpQESgECoFBXQ+oCBQChUBBRaAQ
        KAQKgUFlEahQESgECoGCikAhUAgUBIMCAAAAIQwAAAIAAAAUAAAAAAAAACUQAABRAAAAGAAAAAAAAAAAfgD+AAAAAC9wcml2YXRl
        L3RtcC9xZy1kaWEtZml4dHVyZS9GaXh0dXJlL1NvdXJjZXMvRml4dHVyZS9XYXJucy5zd2lmdAAVAHCgCgAAAE5vVXNhZ2VAaHR0
        cHM6Ly9kb2NzLnN3aWZ0Lm9yZy9jb21waWxlci9kb2N1bWVudGF0aW9uL2RpYWdub3N0aWNzL25vLXVzYWdlAAAXgBCAKAAAAGh0
        dHBzOi8vZG9jcy5zd2lmdC5vcmcvY29tcGlsZXIvZG9jdW1lbnRhdGlvbi9kaWFnbm9zdGljcy9uby11c2FnZQAApGAAAACQAAAA
        oAkAABBAACQAZAByZXN1bHQgb2YgY2FsbCB0byAnbG91ZCgpJyBpcyB1bnVzZWQWDAAAABoAAAA8AQAAggEAAMADAAAAKAAAAAAA
        """

    /// `Clean.dia`: 268 bytes, the metadata block and nothing else.
    static let cleanBase64 = """
        RElBRwEIAAA8AAAABwGyQLRCOdBDODwggS2UgzzMQzq8gzscBIhigEBxECQLBCmkQzicw0MikEI6hMM5pII7mMM7PCTDLMjDOMhC
        OLjDOZTDA1KMQjjQgyuEQzuUw0NCkEI6hMM5mAI7hMM5PCSGKaQDO5SDK4RDO5TDg3GYQjrgQyrQw8OEzMI71IM8jEM5mEI6sEM5
        jMI7uAM9lIM70MM8HASJqoAMKgKFQCFQiBIlMKhkgcAgSE0HqAgUAoVAQUWgECgECkkCUQKDahpQESgECoFBXQ+oCBQChUBBRaAQ
        KAQKgUFlEahQESgECoGCikAhUAgUBIMCAAAAIQwAAAIAAAAUAAAAAAAAAA==
        """

    static func bytes(_ base64: String) throws -> [UInt8] {
        let joined = base64.filter { !$0.isWhitespace }
        return [UInt8](try #require(Data(base64Encoded: joined)))
    }

    @Test("A real Swift 6.4 .dia decodes to its one warning: path, line, column, text and group")
    func decodesOneWarning() throws {
        let bytes = try Self.bytes(Self.warnsBase64)
        #expect(bytes.count == 600)

        let diagnostics = try SerializedDiagnosticsReader.diagnostics(fromBytes: bytes)

        #expect(diagnostics.count == 1)
        let warning = try #require(diagnostics.first)
        #expect(warning.severity == .warning)
        #expect(warning.filePath == "/private/tmp/qg-dia-fixture/Fixture/Sources/Fixture/Warns.swift")
        #expect(warning.lineNumber == 6)
        #expect(warning.columnNumber == 9)
        #expect(warning.message == "result of call to 'loud()' is unused [#NoUsage]")
        #expect(warning.ruleId == "swift-compiler")
    }

    @Test("An empty .dia — a file that compiled clean — decodes to no diagnostics")
    func decodesEmptyRecord() throws {
        let bytes = try Self.bytes(Self.cleanBase64)
        #expect(bytes.count == 268)

        let diagnostics = try SerializedDiagnosticsReader.diagnostics(fromBytes: bytes)

        #expect(diagnostics.isEmpty)
    }

    @Test(
        "Truncated input throws at every length; nothing traps",
        arguments: [0, 1, 4, 5, 8, 16, 100, 267, 300, 400, 512, 599]
    )
    func truncatedInputThrows(length: Int) throws {
        let whole = try Self.bytes(Self.warnsBase64)
        let truncated = Array(whole.prefix(length))

        #expect(throws: (any Error).self) {
            _ = try SerializedDiagnosticsReader.diagnostics(fromBytes: truncated)
        }
    }

    @Test("Input that is not a DIAG bitstream throws")
    func nonDiagInputThrows() throws {
        // The right length and the wrong signature: a bitcode file, say, or anything else that
        // landed at this path.
        var wrongMagic = try Self.bytes(Self.warnsBase64)
        wrongMagic.replaceSubrange(0..<4, with: Array("BC\u{C0}\u{DE}".unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }))
        #expect(throws: (any Error).self) {
            _ = try SerializedDiagnosticsReader.diagnostics(fromBytes: wrongMagic)
        }

        // Sixteen arbitrary bytes — what test 9 writes over a real record.
        let arbitrary: [UInt8] = [0x9E, 0x37, 0x79, 0xB9, 0x7F, 0x4A, 0x7C, 0x15, 0xF3, 0x9C, 0xC0, 0x60, 0x5C, 0xED, 0xC8, 0x34]
        #expect(throws: (any Error).self) {
            _ = try SerializedDiagnosticsReader.diagnostics(fromBytes: arbitrary)
        }
    }

    @Test("Every single-byte corruption of a real record either decodes or throws")
    func corruptedInputNeverTraps() throws {
        // Not an assertion about *what* a corrupt record decodes to — only that reading one is
        // total. The vendored reader trapped on malformed input (`precondition`, `fatalError`,
        // force unwraps); this copy reads files from disk and must not.
        let whole = try Self.bytes(Self.warnsBase64)
        var decoded = 0
        var threw = 0
        for index in whole.indices {
            for replacement: UInt8 in [0x00, 0xFF, whole[index] ^ 0x55] {
                var corrupt = whole
                corrupt[index] = replacement
                switch Result(catching: { try SerializedDiagnosticsReader.diagnostics(fromBytes: corrupt) }) {
                case .success: decoded += 1
                case .failure: threw += 1
                }
            }
        }
        // Reaching this line at all is the result: 600 bytes, three corruptions each.
        #expect(decoded + threw == 1800)
        // And corruption is detected, not absorbed: flipping the signature alone accounts for
        // twelve throws.
        #expect(threw >= 12)
    }

    @Test("A diagnostic without a group renders as its bare text")
    func rendersMessageWithoutGroup() {
        #expect(SerializedDiagnosticsReader.message(text: "variable 'x' was never used", category: nil)
            == "variable 'x' was never used")
        #expect(SerializedDiagnosticsReader.message(text: "variable 'x' was never used", category: "")
            == "variable 'x' was never used")
        #expect(SerializedDiagnosticsReader.message(text: "result is unused", category: "NoUsage")
            == "result is unused [#NoUsage]")
    }
}
