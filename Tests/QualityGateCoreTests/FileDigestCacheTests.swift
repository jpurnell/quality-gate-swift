import Foundation
import Testing
@testable import QualityGateCore

// MARK: - Helpers

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("qg-digest-cache-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeFile(_ content: String, in dir: URL, named name: String = UUID().uuidString) throws -> String {
    let url = dir.appendingPathComponent(name)
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url.path
}

// MARK: - FileDigestCache

@Suite("FileDigestCache")
struct FileDigestCacheTests {

    @Test("Cache returns the same digest direct hashing produces")
    func agreesWithDirectHashing() throws {
        let dir = try makeTempDir()
        let file = try writeFile("hello", in: dir)
        let cache = FileDigestCache()
        #expect(cache.digest(for: file) == CheckerFingerprint.fileDigest(file))
    }

    @Test("A missing file digests to the same sentinel as direct hashing")
    func missingFileSentinelAgrees() throws {
        let dir = try makeTempDir()
        let absent = dir.appendingPathComponent("never-written.txt").path
        let cache = FileDigestCache()
        #expect(cache.digest(for: absent) == CheckerFingerprint.fileDigest(absent))
    }

    @Test("Snapshot semantics: the first read is memoized for the run")
    func memoizesFirstRead() throws {
        let dir = try makeTempDir()
        let file = try writeFile("original", in: dir, named: "f.txt")
        let cache = FileDigestCache()
        let first = cache.digest(for: file)
        try FileManager.default.removeItem(atPath: file)
        // Direct hashing now sees the deletion; the per-run cache must not.
        #expect(CheckerFingerprint.fileDigest(file) == "<absent>")
        #expect(cache.digest(for: file) == first)
    }

    @Test("Distinct paths get distinct entries")
    func distinctPaths() throws {
        let dir = try makeTempDir()
        let f1 = try writeFile("one", in: dir)
        let f2 = try writeFile("two", in: dir)
        let cache = FileDigestCache()
        #expect(cache.digest(for: f1) != cache.digest(for: f2))
    }

    @Test("Concurrent lookups of the same path agree")
    func concurrentLookupsAgree() async throws {
        let dir = try makeTempDir()
        let file = try writeFile("shared", in: dir)
        let cache = FileDigestCache()
        let expected = CheckerFingerprint.fileDigest(file)
        let digests = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<32 {
                group.addTask { cache.digest(for: file) }
            }
            var collected: [String] = []
            for await digest in group {
                collected.append(digest)
            }
            return collected
        }
        #expect(digests.count == 32)
        #expect(digests.allSatisfy { $0 == expected })
    }
}

// MARK: - CheckerFingerprint with a shared cache

@Suite("CheckerFingerprint+FileDigestCache")
struct FingerprintWithDigestCacheTests {

    @Test("Fingerprints are byte-identical with and without a shared cache")
    func fingerprintsIdenticalWithCache() throws {
        let dir = try makeTempDir()
        let f1 = try writeFile("alpha", in: dir)
        let f2 = try writeFile("beta", in: dir)
        let inputs = CacheInputs(files: [f1, f2], salt: "s")
        let cache = FileDigestCache()
        let without = CheckerFingerprint.compute(checkerId: "c", inputs: inputs, gateHash: "g")
        let with = CheckerFingerprint.compute(checkerId: "c", inputs: inputs, gateHash: "g", digests: cache)
        #expect(without == with)
    }

    @Test("Two checkers sharing a cache still get distinct fingerprints")
    func checkerIdStillDistinguishes() throws {
        let dir = try makeTempDir()
        let file = try writeFile("content", in: dir)
        let inputs = CacheInputs(files: [file])
        let cache = FileDigestCache()
        let a = CheckerFingerprint.compute(checkerId: "checker-a", inputs: inputs, gateHash: "g", digests: cache)
        let b = CheckerFingerprint.compute(checkerId: "checker-b", inputs: inputs, gateHash: "g", digests: cache)
        #expect(a != b)
    }
}

// MARK: - Canonical salt

@Suite("CheckerFingerprint.canonicalSalt")
struct CanonicalSaltTests {

    @Test("Equal values salt identically regardless of dictionary storage history")
    func saltIsCanonicalAcrossStorageHistories() throws {
        // Two equal dictionaries whose hash tables grew differently: a literal, and one
        // built through inserts and removals with reserved capacity. Their iteration
        // orders can differ, which is exactly the nondeterminism an unsorted JSONEncoder
        // leaks into cache salts (and, across processes, seeded hashing makes leak
        // certain — the doc-generated perpetual-miss bug).
        let literal = ["alpha": 1, "beta": 2, "gamma": 3, "delta": 4, "epsilon": 5]
        var grown = [String: Int]()
        grown.reserveCapacity(512)
        for (key, value) in [("zeta", 6), ("alpha", 1), ("beta", 2), ("gamma", 3), ("delta", 4), ("epsilon", 5)] {
            grown[key] = value
        }
        grown.removeValue(forKey: "zeta")
        #expect(literal == grown)
        #expect(CheckerFingerprint.canonicalSalt(literal) == CheckerFingerprint.canonicalSalt(grown))
        // A SHA-256 hex digest is exactly 64 characters — pins that encoding succeeded.
        #expect(CheckerFingerprint.canonicalSalt(literal)?.count == 64)
    }

    @Test("Different values salt differently")
    func differentValuesDifferentSalts() throws {
        #expect(CheckerFingerprint.canonicalSalt(["k": "a"]) != CheckerFingerprint.canonicalSalt(["k": "b"]))
    }
}

// MARK: - Derived artifacts in ResultCache

@Suite("ResultCache artifacts")
struct ResultCacheArtifactTests {

    private struct SampleArtifact: Codable, Equatable {
        var name: String
        var score: Int
    }

    @Test("An artifact round-trips under (artifactId, fingerprint)")
    func artifactRoundTrip() throws {
        let cache = ResultCache(directory: try makeTempDir())
        let artifact = SampleArtifact(name: "orientation", score: 42)
        cache.storeArtifact(artifact, artifactId: "telemetry-legibility", fingerprint: "fp-1")
        let loaded = cache.loadArtifact(SampleArtifact.self, artifactId: "telemetry-legibility", fingerprint: "fp-1")
        #expect(loaded == artifact)
    }

    @Test("A different fingerprint is a miss")
    func differentFingerprintMisses() throws {
        let cache = ResultCache(directory: try makeTempDir())
        cache.storeArtifact(SampleArtifact(name: "a", score: 1), artifactId: "telemetry-complexity", fingerprint: "fp-1")
        let loaded = cache.loadArtifact(SampleArtifact.self, artifactId: "telemetry-complexity", fingerprint: "fp-2")
        #expect(loaded == nil)
    }

    @Test("A corrupt entry is a miss, never a crash")
    func corruptEntryIsMiss() throws {
        let dir = try makeTempDir()
        let cache = ResultCache(directory: dir)
        cache.storeArtifact(SampleArtifact(name: "a", score: 1), artifactId: "telemetry-complexity", fingerprint: "fp-1")
        // Corrupt every entry in the directory.
        for entry in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            try Data("not json".utf8).write(to: entry)
        }
        let loaded = cache.loadArtifact(SampleArtifact.self, artifactId: "telemetry-complexity", fingerprint: "fp-1")
        #expect(loaded == nil)
    }
}
