/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

// Vendored from swift-tools-support-core (https://github.com/swiftlang/swift-tools-support-core),
// commit c574915fe88e942e4c4c93376f022daa2ecf05f9, file Sources/TSCUtility/Bits.swift.
//
// Modified for quality-gate-swift, 2026-10-04:
//   - `TSCBasic.ByteString` replaced by `[UInt8]`, so the package gains no dependency.
//   - Every `precondition` became a thrown `Bits.Cursor.Error`. A `.dia` file is input read from
//     disk; a malformed one must be reported, never trap the gate.
//   - `withUnsafeBytes` replaced by bounds-checked array subscripts.
//   - The unused `RandomAccessCollection` conformance was removed.

/// A bit-addressed view of a byte buffer, least-significant bit first.
struct Bits: Sendable {
    /// The bytes being read.
    var buffer: [UInt8]

    /// The number of bits in the buffer.
    var count: Int { buffer.count * 8 }

    /// Reads `count` bits starting at bit `offset`, least-significant first.
    ///
    /// - Throws: `Cursor.Error.invalidWidth` for a width outside `0...64`, and
    ///   `Cursor.Error.bufferOverflow` when the range runs past the end of the buffer.
    func readBits(atOffset offset: Int, count: Int) throws -> UInt64 {
        guard count >= 0, count <= 64 else { throw Cursor.Error.invalidWidth }
        guard offset >= 0, offset <= self.count - count else { throw Cursor.Error.bufferOverflow }

        let upperBound = offset + count
        let topByteIndex = upperBound >> 3
        var result: UInt64 = 0
        if upperBound & 7 != 0 {
            let mask: UInt8 = (1 << UInt8(upperBound & 7)) &- 1
            result = UInt64(buffer[topByteIndex] & mask)
        }
        for index in ((offset >> 3)..<(upperBound >> 3)).reversed() {
            result <<= 8
            result |= UInt64(buffer[index])
        }
        if offset & 7 != 0 {
            result >>= UInt64(offset & 7)
        }
        return result
    }

    /// A forward-only reading position in a `Bits` buffer.
    struct Cursor: Sendable {
        /// Why a read could not be performed.
        enum Error: Swift.Error {
            /// The read ran past the end of the buffer.
            case bufferOverflow
            /// A byte-oriented read was attempted at a position that is not byte-aligned, or an
            /// alignment was requested that is not a power of two.
            case misaligned
            /// A bit width outside what a 64-bit value can hold.
            case invalidWidth
        }

        /// The buffer being read.
        let buffer: Bits
        private var offset: Int = 0

        /// Creates a cursor at the start of `buffer`.
        init(buffer: [UInt8]) {
            self.buffer = Bits(buffer: buffer)
        }

        /// Whether nothing has been read yet.
        var isAtStart: Bool { offset == 0 }

        /// Whether every bit has been read.
        var isAtEnd: Bool { offset >= buffer.count }

        /// The number of bits not yet read.
        var remainingBits: Int { max(0, buffer.count - offset) }

        /// Reads `count` bits and advances past them.
        mutating func read(_ count: Int) throws -> UInt64 {
            let value = try buffer.readBits(atOffset: offset, count: count)
            offset += count
            return value
        }

        /// Reads `count` whole bytes from a byte-aligned position and advances past them.
        mutating func read(bytes count: Int) throws -> ArraySlice<UInt8> {
            let start = try alignedByteRangeStart(count: count)
            offset += count << 3
            return buffer.buffer[start..<(start + count)]
        }

        /// Advances past `count` whole bytes from a byte-aligned position.
        mutating func skip(bytes count: Int) throws {
            _ = try alignedByteRangeStart(count: count)
            offset += count << 3
        }

        /// Advances to the next multiple of `align` bits; `align` must be a power of two.
        mutating func advance(toBitAlignment align: Int) throws {
            guard align > 0, align & (align - 1) == 0 else { throw Error.misaligned }
            guard offset & (align - 1) != 0 else { return }
            let aligned = (offset + align) & ~(align - 1)
            guard aligned <= buffer.count else { throw Error.bufferOverflow }
            offset = aligned
        }

        /// The byte index at which a `count`-byte read would start, after checking that the
        /// cursor is byte-aligned and that the bytes exist.
        private func alignedByteRangeStart(count: Int) throws -> Int {
            guard offset & 0b111 == 0 else { throw Error.misaligned }
            guard count >= 0, count <= remainingBits >> 3 else { throw Error.bufferOverflow }
            return offset >> 3
        }
    }
}
