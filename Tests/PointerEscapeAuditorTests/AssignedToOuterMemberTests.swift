import Foundation
import Testing
@testable import PointerEscapeAuditor
@testable import QualityGateCore

/// `pointer-escape.assigned-to-outer-member`: a borrowed pointer stored into a field or element
/// of a variable that outlives the with-block, where that variable is read again afterwards.
///
/// The motivating case is zlib's `z_stream`: `stream.next_in = buf.baseAddress` inside the
/// closure, `deflate(&stream, …)` after it. Every line is legal Swift; the call reads a pointer
/// whose memory was only lent for the closure's duration.
@Suite("PointerEscapeAuditor: assigned to outer member")
struct AssignedToOuterMemberTests {
    private let ruleId = "pointer-escape.assigned-to-outer-member"

    private func lines(_ result: CheckResult, _ rule: String) -> [Int] {
        result.diagnostics.filter { $0.ruleId == rule }.compactMap(\.lineNumber).sorted()
    }

    // MARK: - Must flag

    @Test("Flags a field assignment whose root is read after the with-block (SwiftZIP shape)")
    func flagsEscapingStreamField() async throws {
        let code = """
        func compress(_ data: Data) -> Int32 {
            var stream = z_stream()
            var srcCopy = [UInt8](data)
            srcCopy.withUnsafeMutableBufferPointer { srcBuf in
                stream.next_in = srcBuf.baseAddress
                stream.avail_in = uInt(srcBuf.count)
            }
            let result = CZlib.deflate(&stream, Z_FINISH)
            return result
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(lines(result, ruleId) == [5])
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.severity == .error)
    }

    @Test("Flags both buffers when input and output are set in separate with-blocks")
    func flagsTwoSeparateBlocks() async throws {
        let code = """
        func inflateAll(_ data: Data, into dest: inout [UInt8]) -> Int32 {
            var stream = z_stream()
            var src = [UInt8](data)
            src.withUnsafeMutableBufferPointer { s in
                stream.next_in = s.baseAddress
            }
            dest.withUnsafeMutableBufferPointer { d in
                stream.next_out = d.baseAddress
            }
            return CZlib.inflate(&stream, Z_FINISH)
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(lines(result, ruleId) == [5, 8])
        #expect(result.diagnostics.count == 2)
    }

    @Test("Flags a subscript assignment whose collection is used after the with-block")
    func flagsSubscriptAssignment() async throws {
        let code = """
        func gather(_ bytes: [UInt8]) {
            var buf: [UnsafePointer<UInt8>?] = [nil]
            bytes.withUnsafeBufferPointer { p in
                buf[0] = p.baseAddress
            }
            use(buf)
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(lines(result, ruleId) == [4])
        #expect(result.diagnostics.count == 1)
    }

    @Test("Flags a nested member chain when the root is used after the with-block")
    func flagsDeepChain() async throws {
        let code = """
        func wire(_ bytes: [UInt8]) {
            var outer = Holder()
            bytes.withUnsafeBufferPointer { p in
                outer.a.b = p.baseAddress
            }
            consume(outer)
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(lines(result, ruleId) == [4])
        #expect(result.diagnostics.count == 1)
    }

    @Test(
        "Flags every derived pointer form",
        arguments: [
            "p.baseAddress!",
            "p.baseAddress?.advanced(by: 1)",
            "UnsafeMutablePointer(p.baseAddress)",
            "UnsafeMutableRawPointer(p.baseAddress)",
            "p",
        ]
    )
    func flagsDerivedForms(_ rhs: String) async throws {
        let code = """
        func wire(_ bytes: inout [UInt8]) -> Int32 {
            var stream = z_stream()
            bytes.withUnsafeMutableBufferPointer { p in
                stream.next_in = \(rhs)
            }
            return CZlib.deflate(&stream, Z_FINISH)
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(lines(result, ruleId) == [4])
        #expect(result.diagnostics.count == 1)
    }

    @Test("Flags when the stale field itself is read after the with-block")
    func flagsSameFieldRead() async throws {
        let code = """
        func wire(_ bytes: [UInt8]) -> UInt8? {
            var holder = Holder()
            bytes.withUnsafeBufferPointer { p in
                holder.ptr = p.baseAddress
            }
            return holder.ptr?.pointee
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(lines(result, ruleId) == [4])
        #expect(result.diagnostics.count == 1)
    }

    @Test("Flags when a loop brings an earlier read round again after the with-block")
    func flagsLoopCarriedRead() async throws {
        let code = """
        func pump(_ chunks: [[UInt8]]) {
            var stream = z_stream()
            for var chunk in chunks {
                _ = CZlib.deflate(&stream, Z_NO_FLUSH)
                chunk.withUnsafeMutableBufferPointer { p in
                    stream.next_in = p.baseAddress
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(lines(result, ruleId) == [6])
        #expect(result.diagnostics.count == 1)
    }

    @Test("Flags an inner-block pointer when the outer block reads the same field afterwards")
    func flagsInnerPointerReadInOuter() async throws {
        let code = """
        func wire(_ a: [UInt8], _ b: [UInt8]) -> Int32 {
            var stream = z_stream()
            return a.withUnsafeBufferPointer { outer in
                b.withUnsafeBufferPointer { inner in
                    stream.next_in = inner.baseAddress
                }
                return CZlib.deflate(&stream, Z_FINISH)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(lines(result, ruleId) == [5])
        #expect(result.diagnostics.count == 1)
    }

    @Test("Flags an inout parameter's field: the caller reads it after the function returns")
    func flagsInoutParameterRoot() async throws {
        let code = """
        func attach(_ stream: inout z_stream, _ bytes: [UInt8]) {
            bytes.withUnsafeBufferPointer { p in
                stream.next_in = UnsafeMutablePointer(mutating: p.baseAddress)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(lines(result, ruleId) == [3])
        #expect(result.diagnostics.count == 1)
    }

    @Test("Flags an implicit-self property's field: the instance outlives the call")
    func flagsImplicitSelfPropertyRoot() async throws {
        let code = """
        final class Inflater {
            var stream = z_stream()
            func attach(_ bytes: [UInt8]) {
                bytes.withUnsafeBufferPointer { p in
                    stream.next_in = UnsafeMutablePointer(mutating: p.baseAddress)
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(lines(result, ruleId) == [5])
        #expect(result.diagnostics.count == 1)
    }

    // MARK: - self roots stay under stored-in-property

    @Test("self.x is stored-in-property, flagged regardless of later use")
    func selfMemberIsStoredInProperty() async throws {
        let code = """
        final class Holder {
            var ptr: UnsafePointer<Int>?
            func capture(_ x: Int) {
                withUnsafePointer(to: x) { p in
                    self.ptr = p
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(lines(result, "pointer-escape.stored-in-property") == [5])
        #expect(result.diagnostics.count == 1)
    }

    @Test("self.a.b is stored-in-property too")
    func deepSelfMemberIsStoredInProperty() async throws {
        let code = """
        final class Inflater {
            var state = State()
            func attach(_ bytes: [UInt8]) {
                bytes.withUnsafeBufferPointer { p in
                    self.state.stream.next_in = p.baseAddress
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(lines(result, "pointer-escape.stored-in-property") == [5])
        #expect(result.diagnostics.count == 1)
    }

    // MARK: - Must NOT flag

    @Test("Does not flag the nested shape where every read happens inside the closures (ZlibStream)")
    func ignoresNestedCorrectShape() async throws {
        let code = """
        func inflate(_ data: Data, limit: Int) throws -> Data {
            var stream = z_stream()
            defer { inflateEnd(&stream) }
            var output = Data()
            var chunk = [UInt8](repeating: 0, count: 1024)
            var source = [UInt8](data)
            var status: Int32 = Z_OK
            let n = uInt(source.count)
            try source.withUnsafeMutableBufferPointer { input in
                stream.next_in = input.baseAddress
                stream.avail_in = n
                repeat {
                    let produced: Int = chunk.withUnsafeMutableBufferPointer { out -> Int in
                        stream.next_out = out.baseAddress
                        stream.avail_out = uInt(out.count)
                        status = inflate(&stream, Z_NO_FLUSH)
                        return out.count - Int(stream.avail_out)
                    }
                    if produced > 0 { output.append(contentsOf: chunk[0..<produced]) }
                    if status == Z_BUF_ERROR, produced == 0, stream.avail_in == 0 {
                        throw ZIPError.truncated
                    }
                } while status != Z_STREAM_END
            }
            guard status == Z_STREAM_END else { throw ZIPError.truncated }
            return output
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Does not flag when only unrelated fields of the root are read afterwards")
    func ignoresDisjointFieldReads() async throws {
        let code = """
        func wire(_ bytes: inout [UInt8], _ dest: inout [UInt8]) -> Int {
            var stream = z_stream()
            let status: Int32 = bytes.withUnsafeMutableBufferPointer { input in
                dest.withUnsafeMutableBufferPointer { output in
                    stream.next_in = input.baseAddress
                    stream.next_out = output.baseAddress
                    return CZlib.deflate(&stream, Z_FINISH)
                }
            }
            return Int(stream.total_out) + Int(status)
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Does not flag an outer variable that is never referenced after the with-block")
    func ignoresRootNotReferencedAfter() async throws {
        let code = """
        func wire(_ bytes: [UInt8]) {
            var holder = Holder()
            bytes.withUnsafeBufferPointer { p in
                holder.ptr = p.baseAddress
                use(holder)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Does not flag when the field is overwritten, not read, after the with-block")
    func ignoresLaterOverwrite() async throws {
        let code = """
        func wire(_ bytes: [UInt8]) {
            var holder = Holder()
            bytes.withUnsafeBufferPointer { p in
                holder.ptr = p.baseAddress
                use(holder)
            }
            holder.ptr = nil
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Does not flag a root declared inside the with-block")
    func ignoresRootDeclaredInsideClosure() async throws {
        let code = """
        func wire(_ bytes: inout [UInt8]) -> Int32 {
            bytes.withUnsafeMutableBufferPointer { p in
                var stream = z_stream()
                stream.next_in = p.baseAddress
                return CZlib.deflate(&stream, Z_FINISH)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Does not flag an outer pointer set in an inner block and read only inside the outer one")
    func ignoresOuterPointerUsedWithinOuter() async throws {
        let code = """
        func wire(_ a: [UInt8], _ b: [UInt8]) -> Int32 {
            var stream = z_stream()
            return a.withUnsafeBufferPointer { outer in
                b.withUnsafeBufferPointer { inner in
                    stream.next_in = outer.baseAddress
                }
                return CZlib.deflate(&stream, Z_FINISH)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Does not flag a field assigned a value read through the pointer")
    func ignoresValueAssignment() async throws {
        let code = """
        func wire(_ bytes: [UInt8]) -> Int {
            var stats = Stats()
            bytes.withUnsafeBufferPointer { p in
                stats.count = p.count
                stats.first = p.first
            }
            return stats.count
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.isEmpty)
    }

    /// IconquerAI `AccelerateGVNWeights.readTensorInto`: an element read through the buffer is a
    /// `Float`, not the buffer. Found by measuring this rule against the portfolio.
    @Test("Does not flag copying an element out of the buffer into an outer array")
    func ignoresElementCopy() async throws {
        let code = """
        func read(_ slice: Data, into dest: inout [Float], count: Int) -> Float {
            slice.withUnsafeBytes { rawBuf in
                let floatBuf = rawBuf.bindMemory(to: Float.self)
                for i in 0..<count {
                    dest[i] = floatBuf[i]
                }
            }
            return dest[0]
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Still flags a range subscript: a slice of the buffer keeps pointing into it")
    func flagsRangeSlice() async throws {
        let code = """
        func wire(_ bytes: [UInt8]) {
            var holder = Holder()
            bytes.withUnsafeBufferPointer { p in
                holder.window = p[0..<2]
            }
            use(holder)
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(lines(result, ruleId) == [4])
        #expect(result.diagnostics.count == 1)
    }

    @Test("A defer written before the with-block is not counted as a later read")
    func deferBeforeBlockIsNotALaterRead() async throws {
        let code = """
        func wire(_ bytes: [UInt8]) {
            var stream = z_stream()
            defer { inflateEnd(&stream) }
            bytes.withUnsafeBufferPointer { p in
                stream.next_in = UnsafeMutablePointer(mutating: p.baseAddress)
                _ = inflate(&stream, Z_FINISH)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.isEmpty)
    }
}
