/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2020-2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

// Vendored from swift-tools-support-core (https://github.com/swiftlang/swift-tools-support-core),
// commit c574915fe88e942e4c4c93376f022daa2ecf05f9, file Sources/TSCUtility/Bitstream.swift.
//
// Modified for quality-gate-swift, 2026-10-04:
//   - Everything is internal to `BuildChecker`; upstream's declarations are public.
//   - `BitcodeElement.Record.fields` is an owned `[UInt64]`, not an `UnsafeBufferPointer` valid
//     only for the duration of a visitor callback. Nothing can escape a record's lifetime
//     because a record no longer has one.
//   - `Bitcode.Signature.init(string:)` is failable instead of trapping on a string that is not
//     four bytes long.
//   - `Bitstream.AbbreviationID` is a namespace of `UInt64` constants rather than a
//     `RawRepresentable` struct; the reader only ever compared raw values.
//   - Declarations the reader does not use were removed: `Bitcode`'s stored properties,
//     `BitcodeElement.Block`, `BlockInfo`, `Bitstream.BlockID`, the payload's
//     `CustomStringConvertible` conformance, and `Abbreviation.Operand`'s writer-side
//     `isLiteral` and `encodedKind`.

/// A namespace for the [LLVM bitstream container format](https://llvm.org/docs/BitCodeFormat.html#bitstream-container-format).
enum Bitcode {}

/// An element of a bitstream.
enum BitcodeElement {
    /// A record: a numeric code, its operand fields, and an optional trailing payload.
    struct Record: Sendable {
        /// The trailing operand of an abbreviated record, when it has one.
        enum Payload: Sendable {
            /// No trailing payload.
            case none
            /// A trailing array of values.
            case array([UInt64])
            /// A trailing array of char6-encoded characters.
            case char6String(String)
            /// A trailing blob of bytes.
            case blob(ArraySlice<UInt8>)
        }

        /// The record code.
        var id: UInt64
        /// The record's operand fields, excluding the code and any payload.
        var fields: [UInt64]
        /// The record's trailing payload.
        var payload: Payload
    }
}

extension Bitcode {
    /// The four-byte "magic number" at the start of a bitstream.
    struct Signature: Equatable, Sendable {
        private var value: UInt32

        /// Creates a signature from its little-endian 32-bit value.
        init(value: UInt32) {
            self.value = value
        }

        /// Creates a signature from its four ASCII characters, or `nil` if `string` is not
        /// exactly four bytes long.
        init?(string: String) {
            guard string.utf8.count == 4 else { return nil }
            var result: UInt32 = 0
            for byte in string.utf8.reversed() {
                result <<= 8
                result |= UInt32(byte)
            }
            self.value = result
        }
    }
}

/// A visitor which receives callbacks while reading a bitstream.
protocol BitstreamVisitor {
    /// Customization point to validate a bitstream's signature or "magic number".
    func validate(signature: Bitcode.Signature) throws
    /// Called when a new block is encountered. Return `true` to enter the block
    /// and read its contents, or `false` to skip it.
    mutating func shouldEnterBlock(id: UInt64) throws -> Bool
    /// Called when a block is exited.
    mutating func didExitBlock() throws
    /// Called whenever a record is encountered.
    mutating func visit(record: BitcodeElement.Record) throws
}

/// A top-level namespace for all bitstream-related structures.
enum Bitstream {}

extension Bitstream {
    /// An `Abbreviation` represents the encoding definition for a user-defined
    /// record. An `Abbreviation` is the primary form of compression available in
    /// a bitstream file.
    struct Abbreviation: Sendable {
        /// One operand of an abbreviation definition.
        indirect enum Operand: Sendable {
            /// A literal value (emitted as a VBR8 field).
            case literal(UInt64)

            /// A fixed-width field.
            case fixed(bitWidth: UInt8)

            /// A VBR-encoded value with the provided chunk width.
            case vbr(chunkBitWidth: UInt8)

            /// An array of values. This expects another operand encoded
            /// directly after indicating the element type.
            /// The array will begin with a vbr6 value indicating the length of
            /// the following array.
            case array(Operand)

            /// A char6-encoded ASCII character.
            case char6

            /// Emitted as a vbr6 value, padded to a 32-bit boundary and then
            /// an array of 8-bit objects.
            case blob

            /// Whether this operand is a trailing array or blob rather than a scalar field.
            var isPayload: Bool {
                switch self {
                case .array, .blob: return true
                case .literal, .fixed, .vbr, .char6: return false
                }
            }
        }

        /// The abbreviation's operands, in encoding order.
        var operands: [Operand] = []

        /// Creates an abbreviation from its operands.
        init(_ operands: [Operand]) {
            self.operands = operands
        }
    }
}

extension Bitstream {
    /// A `BlockInfoCode` enumerates the bits that occur in the metadata for
    /// a block or record. Of these bits, only `setBID` is required. If
    /// a name is given to a block or record with `blockName` or
    /// `setRecordName`, debugging tools like `llvm-bcanalyzer` can be used to
    /// introspect the structure of blocks and records in the bitstream file.
    enum BlockInfoCode: UInt8 {
        /// Indicates which block ID is being described.
        case setBID = 1
        /// An optional element that records which bytes of the record are the
        /// name of the block.
        case blockName = 2
        /// An optional element that records the record ID number and the bytes
        /// for the name of the corresponding record.
        case setRecordName = 3
    }
}

extension Bitstream {
    /// An `AbbreviationID` is a fixed-width field that occurs at the start of
    /// abbreviated data records and inside block definitions.
    ///
    /// Bitstream reserves 4 special abbreviation IDs for its own bookkeeping.
    /// User defined IDs are expected to start at
    /// `Bitstream.AbbreviationID.firstApplicationID`.
    enum AbbreviationID {
        /// Marks the end of the current block.
        static let endBlock: UInt64 = 0
        /// Marks the beginning of a new block.
        static let enterSubblock: UInt64 = 1
        /// Marks the definition of a new abbreviation.
        static let defineAbbreviation: UInt64 = 2
        /// Marks the definition of a new unabbreviated record.
        static let unabbreviatedRecord: UInt64 = 3
        /// The first application-defined abbreviation ID.
        static let firstApplicationID: UInt64 = 4
    }
}
