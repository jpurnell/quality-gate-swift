// CorpusService — the transport-agnostic trust core for Phase 3b.
//
// This module hosts the machinery corpusd will expose: verified identity
// (TokenStore, IdentityEnvelope) and governed escape hatches (ReviewPolicy,
// ReviewQueue). No HTTP, no daemon, no MCP — those are the service shell,
// not the trust semantics.

import Foundation

/// Shared JSON-file persistence for the module's stores.
///
/// Encoding is deterministic (pretty-printed, sorted keys, ISO 8601 dates)
/// so store files diff cleanly under git — the corpus's audit layer.
/// Writes are atomic; a missing file reads as `nil` (an empty store).
enum JSONStoreIO {

    /// Builds the module's deterministic encoder.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Builds the decoder matching ``makeEncoder()``.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Loads and decodes a store file, or returns `nil` when no file exists.
    /// - Parameters:
    ///   - type: The store-file type to decode.
    ///   - path: Absolute path of the store file.
    /// - Returns: The decoded value, or `nil` for a missing file.
    /// - Throws: Decoding or I/O errors for a present-but-unreadable file.
    static func load<Value: Decodable>(_ type: Value.Type, atPath path: String) throws -> Value? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try makeDecoder().decode(type, from: data)
    }

    /// Encodes and atomically writes a store file, creating parent
    /// directories as needed.
    /// - Parameters:
    ///   - value: The store-file value to persist.
    ///   - path: Absolute path of the store file.
    /// - Throws: Encoding or I/O errors.
    static func save<Value: Encodable>(_ value: Value, toPath path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let data = try makeEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }
}

extension Sequence where Element == UInt8 {

    /// Lowercase hexadecimal encoding of a byte sequence.
    ///
    /// Built from `String(_:radix:)` with explicit zero-padding — the
    /// module never uses C-format strings.
    func hexEncoded() -> String {
        map { byte in
            let digits = String(byte, radix: 16)
            return byte < 16 ? "0" + digits : digits
        }
        .joined()
    }
}
