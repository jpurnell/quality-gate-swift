/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

// Vendored from swift-tools-support-core (https://github.com/swiftlang/swift-tools-support-core),
// commit c574915fe88e942e4c4c93376f022daa2ecf05f9, file Sources/TSCUtility/BitstreamReader.swift.
//
// Modified for quality-gate-swift, 2026-10-04:
//   - `TSCBasic.ByteString` replaced by `[UInt8]`.
//   - Every `precondition`, `fatalError`, force unwrap and trapping integer conversion became a
//     thrown `BitstreamReader.Error`. Upstream reads files the toolchain itself just wrote; this
//     copy reads whatever is on disk, and a truncated or overwritten `.dia` must surface as
//     "could not be read", never as a crash of the gate.
//   - Records are returned as owned values (`[UInt64]` fields) rather than passed to a closure
//     as a view over a temporary `UnsafeMutableBufferPointer`.
//   - The two recursive readers take an explicit depth and refuse to nest past a fixed bound,
//     and a trailing array's declared length is checked against the bits that remain, so a
//     corrupt length cannot drive an unbounded loop.
//   - `BLOCKINFO` block and record names are validated and discarded; upstream stored them in a
//     `blockInfo` table nothing here reads.

extension Bitcode {
    /// Traverse a bitstream using the specified `visitor`, which will receive
    /// callbacks when blocks and records are encountered.
    ///
    /// - Throws: `BitstreamReader.Error` or `Bits.Cursor.Error` when `bytes` is not a
    ///   well-formed bitstream, and whatever the visitor throws.
    static func read<Visitor: BitstreamVisitor>(bytes: [UInt8], using visitor: inout Visitor) throws {
        guard bytes.count > 4 else { throw BitstreamReader.Error.truncated }
        var reader = BitstreamReader(buffer: bytes)
        try visitor.validate(signature: reader.readSignature())
        try reader.readBlock(
            id: BitstreamReader.fakeTopLevelBlockID,
            abbrevWidth: 2,
            abbrevInfo: [],
            depth: 0,
            visitor: &visitor
        )
    }
}

private extension Bits.Cursor {
    /// Reads a variable-bit-rate value encoded in chunks of `width` bits.
    mutating func readVBR(_ width: Int) throws -> UInt64 {
        guard width > 1, width <= 32 else { throw BitstreamReader.Error.invalidAbbrev }
        let testBit = UInt64(1) << UInt64(width - 1)
        let mask = testBit &- 1

        var result: UInt64 = 0
        var offset: UInt64 = 0
        var next: UInt64
        repeat {
            next = try self.read(width)
            result |= (next & mask) << offset
            offset += UInt64(width - 1)
            if offset > 64 { throw BitstreamReader.Error.vbrOverflow }
        } while next & testBit != 0

        return result
    }

    /// Reads a VBR value that must fit an `Int` — a count or a length.
    mutating func readVBRCount(_ width: Int) throws -> Int {
        guard let count = Int(exactly: try readVBR(width)) else {
            throw BitstreamReader.Error.vbrOverflow
        }
        return count
    }

    /// Reads a VBR value that must fit a `UInt8` — a bit width.
    mutating func readVBRWidth(_ width: Int) throws -> UInt8 {
        guard let value = UInt8(exactly: try readVBR(width)) else {
            throw BitstreamReader.Error.invalidAbbrev
        }
        return value
    }
}

/// Reads an LLVM bitstream, reporting blocks and records to a `BitstreamVisitor`.
struct BitstreamReader {
    /// Why a bitstream could not be read.
    enum Error: Swift.Error {
        /// Too short to hold a signature and any content.
        case truncated
        /// An abbreviation definition, or a record encoded with one, is not well-formed.
        case invalidAbbrev
        /// A variable-bit-rate value does not fit the integer it is read into.
        case vbrOverflow
        /// A `BLOCKINFO` block contains a nested block.
        case nestedBlockInBlockInfo
        /// A `BLOCKINFO` record appeared before the `SETBID` naming the block it describes.
        case missingSETBID
        /// A `BLOCKINFO` record is not one of the three defined kinds, or has the wrong shape.
        case invalidBlockInfoRecord(recordID: UInt64)
        /// A record names an abbreviation its block never defined.
        case noSuchAbbrev(blockID: UInt64, abbrevID: UInt64)
        /// The stream ended inside a block.
        case missingEndBlock(blockID: UInt64)
        /// Blocks nest deeper than any real bitstream does.
        case nestingTooDeep
    }

    /// The deepest block nesting accepted. A `.dia` file nests two levels (a diagnostic block
    /// holding its notes); the bound exists so that depth is a property of this reader rather
    /// than of the input.
    static let maximumBlockDepth = 32

    /// The block ID given to the implicit block that holds the whole stream.
    static let fakeTopLevelBlockID: UInt64 = ~0

    private var cursor: Bits.Cursor
    private var globalAbbrevs: [UInt64: [Bitstream.Abbreviation]] = [:]

    /// Creates a reader positioned at the start of `buffer`.
    init(buffer: [UInt8]) {
        self.cursor = Bits.Cursor(buffer: buffer)
    }

    /// Reads the four-byte signature; valid only as the first read.
    mutating func readSignature() throws -> Bitcode.Signature {
        guard cursor.isAtStart else { throw Error.truncated }
        let bits = try cursor.read(32)
        return Bitcode.Signature(value: UInt32(truncatingIfNeeded: bits))
    }

    /// Reads one operand of an abbreviation definition.
    ///
    /// - Parameter isArrayElement: `true` when reading the element type of an array operand,
    ///   which must itself be a scalar. This is the base case of the one recursive call.
    private mutating func readAbbrevOp(isArrayElement: Bool) throws -> Bitstream.Abbreviation.Operand {
        let isLiteralFlag = try cursor.read(1)
        if isLiteralFlag == 1 {
            return .literal(try cursor.readVBR(8))
        }

        switch try cursor.read(3) {
        case 1:
            return .fixed(bitWidth: try cursor.readVBRWidth(5))
        case 2:
            return .vbr(chunkBitWidth: try cursor.readVBRWidth(5))
        case 3:
            guard !isArrayElement else { throw Error.invalidAbbrev }
            return .array(try readAbbrevOp(isArrayElement: true))
        case 4:
            return .char6
        case 5:
            guard !isArrayElement else { throw Error.invalidAbbrev }
            return .blob
        default:
            throw Error.invalidAbbrev
        }
    }

    /// Reads an abbreviation definition of `numOps` operands.
    private mutating func readAbbrev(numOps: Int) throws -> Bitstream.Abbreviation {
        guard numOps > 0 else { throw Error.invalidAbbrev }

        var operands: [Bitstream.Abbreviation.Operand] = []
        for index in 0..<numOps {
            let operand = try readAbbrevOp(isArrayElement: false)
            operands.append(operand)

            if case .array = operand {
                // An array's element type is encoded as the operand after it, so the array is
                // second to last by the definition's own count.
                guard index == numOps - 2 else { throw Error.invalidAbbrev }
                break
            } else if case .blob = operand {
                guard index == numOps - 1 else { throw Error.invalidAbbrev }
            }
        }

        return Bitstream.Abbreviation(operands)
    }

    /// Reads one scalar operand of an abbreviated record.
    private mutating func readSingleAbbreviatedRecordOperand(
        _ operand: Bitstream.Abbreviation.Operand
    ) throws -> UInt64 {
        switch operand {
        case .char6:
            return try Self.decodeChar6(cursor.read(6))
        case .literal(let value):
            return value
        case .fixed(let width):
            return try cursor.read(Int(width))
        case .vbr(let width):
            return try cursor.readVBR(Int(width))
        case .array, .blob:
            throw Error.invalidAbbrev
        }
    }

    /// The Unicode scalar value of a char6-encoded character (`[a-zA-Z0-9._]`).
    private static func decodeChar6(_ value: UInt64) throws -> UInt64 {
        switch value {
        case 0...25:
            return value + UInt64(("a" as UnicodeScalar).value)
        case 26...51:
            return value + UInt64(("A" as UnicodeScalar).value) - 26
        case 52...61:
            return value + UInt64(("0" as UnicodeScalar).value) - 52
        case 62:
            return UInt64(("." as UnicodeScalar).value)
        case 63:
            return UInt64(("_" as UnicodeScalar).value)
        default:
            throw Error.invalidAbbrev
        }
    }

    /// Reads a record encoded with `abbrev`.
    private mutating func readAbbreviatedRecord(
        _ abbrev: Bitstream.Abbreviation
    ) throws -> BitcodeElement.Record {
        guard let codeOperand = abbrev.operands.first, let lastOperand = abbrev.operands.last else {
            throw Error.invalidAbbrev
        }
        let code = try readSingleAbbreviatedRecordOperand(codeOperand)

        // The first operand is the record code; a trailing array or blob is the payload; what
        // lies between are the fields.
        let lastRegularOperandIndex = abbrev.operands.endIndex - (lastOperand.isPayload ? 1 : 0)
        guard lastRegularOperandIndex >= 1 else { throw Error.invalidAbbrev }

        var fields: [UInt64] = []
        for operand in abbrev.operands[1..<lastRegularOperandIndex] {
            fields.append(try readSingleAbbreviatedRecordOperand(operand))
        }

        let payload: BitcodeElement.Record.Payload
        switch lastOperand {
        case .array(let element):
            payload = try readArrayPayload(element: element)
        case .blob:
            let length = try cursor.readVBRCount(6)
            try cursor.advance(toBitAlignment: 32)
            payload = .blob(try cursor.read(bytes: length))
            try cursor.advance(toBitAlignment: 32)
        case .literal, .fixed, .vbr, .char6:
            payload = .none
        }

        return BitcodeElement.Record(id: code, fields: fields, payload: payload)
    }

    /// Reads a trailing array whose elements are encoded as `element`.
    private mutating func readArrayPayload(
        element: Bitstream.Abbreviation.Operand
    ) throws -> BitcodeElement.Record.Payload {
        let length = try cursor.readVBRCount(6)
        // No well-formed array has more elements than there are bits left to encode them. The
        // check bounds the loop below by the size of the file rather than by a number the file
        // supplies.
        guard length <= cursor.remainingBits else { throw Bits.Cursor.Error.bufferOverflow }

        if case .char6 = element {
            var bytes: [UInt8] = []
            for _ in 0..<length {
                bytes.append(UInt8(truncatingIfNeeded: try readSingleAbbreviatedRecordOperand(element)))
            }
            return .char6String(String(decoding: bytes, as: UTF8.self))
        }

        var elements: [UInt64] = []
        for _ in 0..<length {
            elements.append(try readSingleAbbreviatedRecordOperand(element))
        }
        return .array(elements)
    }

    /// Reads a `BLOCKINFO` block, keeping the abbreviations it defines for other blocks.
    private mutating func readBlockInfoBlock(abbrevWidth: Int) throws {
        var currentBlockID: UInt64?
        while !cursor.isAtEnd {
            switch try cursor.read(abbrevWidth) {
            case Bitstream.AbbreviationID.endBlock:
                try cursor.advance(toBitAlignment: 32)
                return

            case Bitstream.AbbreviationID.enterSubblock:
                throw Error.nestedBlockInBlockInfo

            case Bitstream.AbbreviationID.defineAbbreviation:
                guard let blockID = currentBlockID else {
                    throw Error.missingSETBID
                }
                let numOps = try cursor.readVBRCount(5)
                globalAbbrevs[blockID, default: []].append(try readAbbrev(numOps: numOps))

            case Bitstream.AbbreviationID.unabbreviatedRecord:
                let code = try cursor.readVBR(6)
                let numOps = try cursor.readVBRCount(6)
                var operands: [UInt64] = []
                for _ in 0..<numOps {
                    operands.append(try cursor.readVBR(6))
                }

                switch code {
                case UInt64(Bitstream.BlockInfoCode.setBID.rawValue):
                    guard operands.count == 1 else { throw Error.invalidBlockInfoRecord(recordID: code) }
                    currentBlockID = operands.first
                case UInt64(Bitstream.BlockInfoCode.blockName.rawValue):
                    guard currentBlockID != nil else { throw Error.missingSETBID }
                case UInt64(Bitstream.BlockInfoCode.setRecordName.rawValue):
                    guard currentBlockID != nil else { throw Error.missingSETBID }
                    guard !operands.isEmpty else { throw Error.invalidBlockInfoRecord(recordID: code) }
                default:
                    throw Error.invalidBlockInfoRecord(recordID: code)
                }

            case let abbrevID:
                throw Error.noSuchAbbrev(blockID: 0, abbrevID: abbrevID)
            }
        }
        throw Error.missingEndBlock(blockID: 0)
    }

    /// Reads the block `id`, reporting its contents to `visitor` and recursing into sub-blocks.
    ///
    /// - Parameter depth: How many blocks enclose this one. The recursion stops with
    ///   `Error.nestingTooDeep` at `maximumBlockDepth`.
    mutating func readBlock<Visitor: BitstreamVisitor>(
        id: UInt64,
        abbrevWidth: Int,
        abbrevInfo: [Bitstream.Abbreviation],
        depth: Int,
        visitor: inout Visitor
    ) throws {
        guard depth < Self.maximumBlockDepth else { throw Error.nestingTooDeep }
        var abbrevInfo = abbrevInfo

        while !cursor.isAtEnd {
            switch try cursor.read(abbrevWidth) {
            case Bitstream.AbbreviationID.endBlock:
                try cursor.advance(toBitAlignment: 32)
                try visitor.didExitBlock()
                return

            case Bitstream.AbbreviationID.enterSubblock:
                let blockID = try cursor.readVBR(8)
                let newAbbrevWidth = try cursor.readVBRCount(4)
                try cursor.advance(toBitAlignment: 32)
                let blockLength = try cursor.read(32) * 4

                if blockID == 0 {
                    try readBlockInfoBlock(abbrevWidth: newAbbrevWidth)
                } else if try visitor.shouldEnterBlock(id: blockID) {
                    try readBlock(
                        id: blockID,
                        abbrevWidth: newAbbrevWidth,
                        abbrevInfo: globalAbbrevs[blockID] ?? [],
                        depth: depth + 1,
                        visitor: &visitor
                    )
                } else {
                    guard let byteCount = Int(exactly: blockLength) else { throw Error.vbrOverflow }
                    try cursor.skip(bytes: byteCount)
                }

            case Bitstream.AbbreviationID.defineAbbreviation:
                let numOps = try cursor.readVBRCount(5)
                abbrevInfo.append(try readAbbrev(numOps: numOps))

            case Bitstream.AbbreviationID.unabbreviatedRecord:
                let code = try cursor.readVBR(6)
                let numOps = try cursor.readVBRCount(6)
                var operands: [UInt64] = []
                for _ in 0..<numOps {
                    operands.append(try cursor.readVBR(6))
                }
                try visitor.visit(record: BitcodeElement.Record(id: code, fields: operands, payload: .none))

            case let abbrevID:
                let index = abbrevID - Bitstream.AbbreviationID.firstApplicationID
                guard index < UInt64(abbrevInfo.count) else {
                    throw Error.noSuchAbbrev(blockID: id, abbrevID: abbrevID)
                }
                try visitor.visit(record: try readAbbreviatedRecord(abbrevInfo[Int(index)]))
            }
        }

        guard id == Self.fakeTopLevelBlockID else {
            throw Error.missingEndBlock(blockID: id)
        }
    }
}
