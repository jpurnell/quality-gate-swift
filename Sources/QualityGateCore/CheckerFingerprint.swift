import Foundation
import Crypto

/// The complete set of inputs a checker's result depends on.
///
/// A checker returns this to opt into result caching. It must enumerate **every**
/// input whose change could change the result — biasing to over-inclusion, since
/// over-including only causes extra cache misses (never a wrong reuse).
public struct CacheInputs: Sendable, Equatable {

    /// Absolute paths of files whose contents affect the result.
    public var files: [String]

    /// An extra opaque token folded into the fingerprint (e.g. a digest of the
    /// relevant `Configuration` slice, or a tool version).
    public var salt: String

    /// Creates an input set.
    public init(files: [String], salt: String = "") {
        self.files = files
        self.salt = salt
    }
}

/// Computes a stable digest of a checker's inputs for incremental result caching.
///
/// The digest folds in the checker id, the gate binary hash, a salt, and each input
/// file's path plus a SHA-256 of its contents (files sorted, so the set is
/// order-independent). Because it hashes the **complete** declared input set, an
/// identical digest guarantees an identical checker result — the safety property the
/// cache relies on. A false pass is only possible if the declared inputs *omit* a real
/// input, which is why callers bias to over-inclusion.
public enum CheckerFingerprint {

    /// Returns a hex digest for `(checkerId, inputs, gateHash)`.
    public static func compute(checkerId: String, inputs: CacheInputs, gateHash: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("qg-fingerprint-v1".utf8))
        hasher.update(data: Data(checkerId.utf8))
        hasher.update(data: Data(gateHash.utf8))
        hasher.update(data: Data(inputs.salt.utf8))
        for path in inputs.files.sorted() {
            hasher.update(data: Data("\u{0}path:".utf8))
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data("\u{0}content:".utf8))
            hasher.update(data: Data(fileDigest(path).utf8))
        }
        return hexString(hasher.finalize())
    }

    /// SHA-256 of a file's contents, or a sentinel when the file is missing/unreadable
    /// (so deleting an input file changes the fingerprint).
    static func fileDigest(_ path: String) -> String {
        // SAFETY: CLI tool reads a declared input file to hash it
        guard let data = FileManager.default.contents(atPath: path) else {
            return "<absent>"
        }
        return hexString(SHA256.hash(data: data))
    }

    /// A stable identity hash for the running gate: the executable's size + modification time
    /// plus the active toolchain version. Use as the `gateHash` argument so a gate rebuild
    /// **or** a compiler change invalidates every cached result — a checker can never serve a
    /// result produced by different analysis logic or a different toolchain.
    ///
    /// Size+mtime (rather than hashing the whole binary) keeps this instant: hashing a large
    /// executable on every run is pure waste, and any rebuild/deploy changes the mtime.
    public static func gateIdentityHash(executablePath: String, toolchainVersion: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("qg-gate-identity-v2".utf8))
        // SAFETY: CLI tool reads its own executable's file attributes
        if let attributes = try? FileManager.default.attributesOfItem(atPath: executablePath) {
            let size = (attributes[.size] as? Int) ?? 0
            let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            hasher.update(data: Data("\(size)-\(mtime)".utf8))
        } else {
            hasher.update(data: Data("<no-executable>".utf8))
        }
        hasher.update(data: Data(toolchainVersion.utf8))
        return hexString(hasher.finalize())
    }

    private static let hexDigits = Array("0123456789abcdef")

    private static func hexString<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        var out = ""
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return out
    }
}
