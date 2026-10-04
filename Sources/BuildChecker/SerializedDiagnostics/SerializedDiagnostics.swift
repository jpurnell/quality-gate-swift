/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

// Vendored from swift-tools-support-core (https://github.com/swiftlang/swift-tools-support-core),
// commit c574915fe88e942e4c4c93376f022daa2ecf05f9, file
// Sources/TSCUtility/SerializedDiagnostics.swift.
//
// Modified for quality-gate-swift, 2026-10-04:
//   - `TSCBasic.ByteString` replaced by `[UInt8]`.
//   - Internal to `BuildChecker`; upstream's declarations are public.
//   - Trapping operations became thrown `SerializedDiagnostics.Error`s: an `END_BLOCK` with no
//     block open, a record outside any diagnostic, and integer conversions of values read from
//     the file.
//   - Source ranges, fix-its and Clang's command-line flag are skipped rather than decoded
//     (the `sourceRange` and `fixit` record IDs are gone with them, so those records are
//     ignored as unknown ones are); the build checker reports a diagnostic's location, level,
//     text and category and nothing else. `OwnedRecord` is gone because
//     `BitcodeElement.Record` now owns its fields.
//   - The `CustomNSError` conformance was removed.

/// Represents diagnostics serialized in a .dia file by the Swift compiler or Clang.
struct SerializedDiagnostics: Sendable {
    /// Why a `.dia` file could not be decoded.
    enum Error: Swift.Error {
        /// The file does not start with the `DIAG` signature.
        case badMagic
        /// A record appeared outside any block.
        case unexpectedTopLevelRecord
        /// A block that is neither the metadata block nor a diagnostic block.
        case unknownBlock
        /// A record does not have the shape its kind requires.
        case malformedRecord
        /// The file has no metadata block, so its format version is unknown.
        case noMetadataBlock
        /// A block ended that was never entered.
        case unbalancedBlock
        /// A diagnostic block carries no diagnostic-info record.
        case missingInformation
    }

    private enum BlockID: UInt64 {
        case metadata = 8
        case diagnostic = 9
    }

    private enum RecordID: UInt64 {
        case version = 1
        case diagnosticInfo = 2
        case flag = 4
        case category = 5
        case filename = 6
    }

    /// The serialized diagnostics format version number.
    var versionNumber: Int
    /// Serialized diagnostics.
    var diagnostics: [Diagnostic]

    /// Decodes the contents of a `.dia` file.
    ///
    /// - Throws: `SerializedDiagnostics.Error`, `BitstreamReader.Error` or `Bits.Cursor.Error` when `bytes` is not a
    ///   well-formed serialized-diagnostics file.
    init(bytes: [UInt8]) throws {
        var reader = Reader()
        try Bitcode.read(bytes: bytes, using: &reader)
        guard let version = reader.versionNumber else { throw Error.noMetadataBlock }
        self.versionNumber = version
        self.diagnostics = reader.diagnostics
    }
}

extension SerializedDiagnostics {
    /// One diagnostic read from a `.dia` file.
    struct Diagnostic: Sendable {
        /// The level a diagnostic was emitted at.
        enum Level: UInt64, Sendable {
            case ignored, note, warning, error, fatal, remark
        }

        /// The diagnostic message text.
        var text: String
        /// The level the diagnostic was emitted at.
        var level: Level
        /// The location the diagnostic was emitted at in the source file.
        var location: SourceLocation?
        /// The diagnostic category.
        var category: String?
        /// The diagnostic category documentation URL.
        var categoryURL: String?

        fileprivate init(
            records: [BitcodeElement.Record],
            filenameMap: [UInt64: String],
            categoryMap: CategoryMap
        ) throws {
            var text: String?
            var level: Level?
            var location: SourceLocation?
            var category: String?
            var categoryURL: String?

            for record in records where SerializedDiagnostics.RecordID(rawValue: record.id) == .diagnosticInfo {
                guard record.fields.count == 8,
                      case .blob(let diagnosticBlob) = record.payload
                else { throw Error.malformedRecord }

                text = String(decoding: diagnosticBlob, as: UTF8.self)
                level = Level(rawValue: record.fields[0])
                location = SourceLocation(fields: record.fields[1...4], filenameMap: filenameMap)

                let categoryEntry = categoryMap[record.fields[5]]
                category = categoryEntry?.text
                categoryURL = categoryEntry?.url
            }

            guard let text, let level else {
                throw Error.missingInformation
            }
            self.text = text
            self.level = level
            self.location = location
            self.category = category
            self.categoryURL = categoryURL
        }
    }

    /// Where in a source file a diagnostic was emitted.
    struct SourceLocation: Equatable, Sendable {
        /// The filename associated with the diagnostic.
        var filename: String
        /// The 1-based line.
        var line: UInt64
        /// The 1-based column.
        var column: UInt64
        /// The byte offset in the source file of the diagnostic. Currently, only
        /// Clang includes this, it is set to 0 by Swift.
        var offset: UInt64

        fileprivate init?(fields: ArraySlice<UInt64>, filenameMap: [UInt64: String]) {
            guard fields.count == 4, let filename = filenameMap[fields[fields.startIndex]] else {
                return nil
            }
            self.filename = filename
            self.line = fields[fields.startIndex + 1]
            self.column = fields[fields.startIndex + 2]
            self.offset = fields[fields.startIndex + 3]
        }
    }
}

extension SerializedDiagnostics {
    /// Category text and documentation URL, keyed by the category's ID in the file.
    typealias CategoryMap = [UInt64: (text: String, url: String?)]

    private struct Reader: BitstreamVisitor {
        var diagnosticRecords: [[BitcodeElement.Record]] = []
        var activeBlocks: [BlockID] = []
        var currentBlockID: BlockID? { activeBlocks.last }

        var diagnostics: [Diagnostic] = []
        var versionNumber: Int?
        var filenameMap = [UInt64: String]()
        var categoryMap = CategoryMap()

        func validate(signature: Bitcode.Signature) throws {
            guard signature == Bitcode.Signature(string: "DIAG") else { throw Error.badMagic }
        }

        mutating func shouldEnterBlock(id: UInt64) throws -> Bool {
            guard let blockID = BlockID(rawValue: id) else { throw Error.unknownBlock }
            activeBlocks.append(blockID)
            if currentBlockID == .diagnostic {
                diagnosticRecords.append([])
            }
            return true
        }

        mutating func didExitBlock() throws {
            guard !activeBlocks.isEmpty else { throw Error.unbalancedBlock }
            activeBlocks.removeLast()
            if activeBlocks.isEmpty {
                for records in diagnosticRecords where !records.isEmpty {
                    diagnostics.append(try Diagnostic(
                        records: records,
                        filenameMap: filenameMap,
                        categoryMap: categoryMap
                    ))
                }
                diagnosticRecords = []
            }
        }

        mutating func visit(record: BitcodeElement.Record) throws {
            switch currentBlockID {
            case .metadata:
                guard record.id == RecordID.version.rawValue,
                      record.fields.count == 1,
                      let version = Int(exactly: record.fields[0])
                else { throw Error.malformedRecord }
                versionNumber = version
            case .diagnostic:
                try visitDiagnosticRecord(record)
            case nil:
                throw Error.unexpectedTopLevelRecord
            }
        }

        /// Files a record found inside a diagnostic block: filenames and categories go to
        /// their tables, the flag table is validated and dropped, and everything else is held
        /// until the outermost block closes and the tables are complete.
        private mutating func visitDiagnosticRecord(_ record: BitcodeElement.Record) throws {
            switch SerializedDiagnostics.RecordID(rawValue: record.id) {
            case .filename:
                guard record.fields.count == 4,
                      case .blob(let filenameBlob) = record.payload
                else { throw Error.malformedRecord }
                // record.fields[1] and record.fields[2] are no longer used.
                filenameMap[record.fields[0]] = String(decoding: filenameBlob, as: UTF8.self)
            case .category:
                guard record.fields.count == 2,
                      case .blob(let categoryBlob) = record.payload,
                      let categoryTextLength = Int(exactly: record.fields[1])
                else { throw Error.malformedRecord }
                categoryMap[record.fields[0]] = try Self.splitCategory(
                    String(decoding: categoryBlob, as: UTF8.self),
                    textLength: categoryTextLength
                )
            case .flag:
                guard record.fields.count == 2, case .blob = record.payload else {
                    throw Error.malformedRecord
                }
            default:
                guard let last = diagnosticRecords.indices.last else {
                    throw Error.unexpectedTopLevelRecord
                }
                diagnosticRecords[last].append(record)
            }
        }

        /// Splits a category blob — `Name` or `Name@https://documentation/url` — at the
        /// length the record gives for the name.
        private static func splitCategory(
            _ blob: String,
            textLength: Int
        ) throws -> (text: String, url: String?) {
            guard textLength >= 0, textLength <= blob.count else { throw Error.malformedRecord }

            let text = String(blob.prefix(textLength))
            let afterText = blob.index(blob.startIndex, offsetBy: textLength)
            guard afterText < blob.endIndex, blob[afterText] == "@" else {
                return (text, nil)
            }
            return (text, String(blob[afterText...].dropFirst()))
        }
    }
}
