import Crypto
import Foundation
import Security
#if canImport(os)
import os
#endif

/// A token's public record — what `corpusd token list` shows.
///
/// Deliberately excludes the token itself and the full hash: names and
/// 12-hex prefixes are enough to identify an entry for revocation without
/// making the listing a credential.
public struct IssuedToken: Sendable, Equatable, Codable {
    /// The identity the token was issued to (e.g. `"jordan"`, `"ci-bot"`).
    public let name: String
    /// The first 12 hex characters of the token's SHA-256 hash.
    public let hashPrefix: String
    /// When the token was issued.
    public let issuedAt: Date
    /// When the token was revoked, or `nil` while it is live.
    public let revokedAt: Date?

    /// Creates a token listing record.
    /// - Parameters:
    ///   - name: The identity the token was issued to.
    ///   - hashPrefix: First 12 hex characters of the token's SHA-256 hash.
    ///   - issuedAt: Issuance timestamp.
    ///   - revokedAt: Revocation timestamp, or `nil` while live.
    public init(name: String, hashPrefix: String, issuedAt: Date, revokedAt: Date?) {
        self.name = name
        self.hashPrefix = hashPrefix
        self.issuedAt = issuedAt
        self.revokedAt = revokedAt
    }
}

/// Typed failures from ``TokenStore`` operations.
public enum TokenStoreError: Error, Equatable, Sendable {
    /// A live token already exists under this name; revoke it first.
    case duplicateActiveName(String)
    /// No token was ever issued under this name.
    case unknownName(String)
    /// Every token under this name is already revoked.
    case alreadyRevoked(String)
    /// The system entropy source failed (`SecRandomCopyBytes` status).
    /// Issuing a guessable token would be worse than issuing none.
    case entropyUnavailable(Int32)
}

/// Bearer tokens v1 (Phase 3b §2) — deliberately boring.
///
/// Tokens are random 32-byte values returned hex-encoded exactly once at
/// issuance; the store persists only their SHA-256 hashes, keyed by hash.
/// The raw token is never stored and never logged. Persistence is a
/// deterministic pretty-JSON file written atomically; a missing file is an
/// empty store.
public actor TokenStore {

    /// One token's persisted state. The dictionary key is the full
    /// SHA-256 hash (hex) of the token, so the raw value never appears.
    private struct Record: Sendable, Codable, Equatable {
        var name: String
        var issuedAt: Date
        var revokedAt: Date?
    }

    /// The on-disk shape: a schema version and the hash-keyed records.
    private struct StoreFile: Sendable, Codable, Equatable {
        var version: Int
        var tokens: [String: Record]
    }

    private static let schemaVersion = 1
    private static let hashPrefixLength = 12
    private static let tokenByteCount = 32

    private static let logger = Logger(subsystem: "com.quality-gate", category: "TokenStore")

    private let storePath: String
    private var tokens: [String: Record]

    /// Opens (or lazily creates) the token store at `storePath`.
    ///
    /// A missing file is an empty store. An unreadable file is logged and
    /// treated as empty rather than crashing the daemon; the broken file is
    /// only overwritten by the next successful mutation.
    /// - Parameter storePath: Absolute path of the JSON store file.
    public init(storePath: String) {
        self.storePath = storePath
        do {
            self.tokens = try JSONStoreIO.load(StoreFile.self, atPath: storePath)?.tokens ?? [:]
        } catch {
            Self.logger.error(
                "Token store at \(storePath, privacy: .public) is unreadable; starting empty: \(String(describing: error), privacy: .public)")
            self.tokens = [:]
        }
    }

    /// Issues a new bearer token for `name`.
    ///
    /// The returned 64-hex string is shown exactly once — only its SHA-256
    /// hash is persisted. Delivery to the client is out-of-band.
    /// - Parameters:
    ///   - name: The identity to bind the token to.
    ///   - now: The issuance timestamp.
    /// - Returns: The raw token, hex-encoded. It cannot be recovered later.
    /// - Throws: ``TokenStoreError/duplicateActiveName(_:)`` when a live
    ///   token already exists under `name`; persistence errors otherwise.
    public func issue(name: String, now: Date) throws -> String {
        if tokens.values.contains(where: { $0.name == name && $0.revokedAt == nil }) {
            throw TokenStoreError.duplicateActiveName(name)
        }
        let token = try Self.generateToken()
        tokens[Self.hash(of: token)] = Record(name: name, issuedAt: now, revokedAt: nil)
        try persist()
        return token
    }

    /// Verifies a presented token and returns the identity it belongs to.
    ///
    /// The presented value is hashed and looked up; the raw token is never
    /// stored or logged by this method.
    /// - Parameters:
    ///   - token: The presented bearer token (hex string).
    ///   - now: The verification timestamp, compared against revocation.
    /// - Returns: The identity name for a live matching token, else `nil`.
    public func verify(token: String, now: Date) -> String? {
        guard let record = tokens[Self.hash(of: token)] else { return nil }
        if let revokedAt = record.revokedAt, revokedAt <= now { return nil }
        return record.name
    }

    /// Revokes the live token issued under `name`.
    /// - Parameters:
    ///   - name: The identity whose live token should be revoked.
    ///   - now: The revocation timestamp.
    /// - Throws: ``TokenStoreError/unknownName(_:)`` when no token was ever
    ///   issued under `name`; ``TokenStoreError/alreadyRevoked(_:)`` when
    ///   every token under `name` is already revoked.
    public func revoke(name: String, now: Date) throws {
        guard let key = tokens.first(where: { $0.value.name == name && $0.value.revokedAt == nil })?.key else {
            if tokens.values.contains(where: { $0.name == name }) {
                throw TokenStoreError.alreadyRevoked(name)
            }
            throw TokenStoreError.unknownName(name)
        }
        tokens[key]?.revokedAt = now
        try persist()
    }

    /// Lists every issued token — names and hash prefixes only — sorted by
    /// issuance time (ties broken by name for determinism).
    public func list() -> [IssuedToken] {
        tokens
            .map { key, record in
                IssuedToken(
                    name: record.name,
                    hashPrefix: String(key.prefix(Self.hashPrefixLength)),
                    issuedAt: record.issuedAt,
                    revokedAt: record.revokedAt)
            }
            .sorted { ($0.issuedAt, $0.name) < ($1.issuedAt, $1.name) }
    }

    // MARK: - Internals

    /// Generates a random 32-byte token, hex-encoded (64 characters),
    /// from the system's cryptographic entropy source.
    /// - Throws: ``TokenStoreError/entropyUnavailable(_:)`` when the
    ///   entropy source fails — never a weaker fallback.
    private static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: tokenByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw TokenStoreError.entropyUnavailable(status)
        }
        return bytes.hexEncoded()
    }

    /// SHA-256 of the presented token string's UTF-8 bytes, hex-encoded.
    private static func hash(of token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).hexEncoded()
    }

    /// Atomically writes the current records to the store file.
    private func persist() throws {
        try JSONStoreIO.save(
            StoreFile(version: Self.schemaVersion, tokens: tokens),
            toPath: storePath)
    }
}
