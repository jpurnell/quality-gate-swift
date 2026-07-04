import Foundation

/// Memoizes async construction of a value per key, deduplicating concurrent construction.
///
/// The first caller for a key builds the value; concurrent callers await the same
/// in-flight `Task` and receive the same result. A construction that throws is **not**
/// cached, so a later call retries. Being an actor, all access is serialized safely.
public actor KeyedAsyncCache<Value: Sendable> {

    private var values: [String: Value] = [:]
    private var pending: [String: Task<Value, any Error>] = [:]

    /// Creates an empty cache.
    public init() {}

    /// Returns the cached value for `key`, constructing it once if needed.
    ///
    /// - Parameters:
    ///   - key: The cache key.
    ///   - make: Builds the value on a cache miss. Called at most once per key while it
    ///     succeeds or is in flight.
    /// - Returns: The cached (or freshly constructed) value.
    public func value(
        for key: String,
        make: @Sendable @escaping () async throws -> Value
    ) async throws -> Value {
        if let existing = values[key] {
            return existing
        }
        if let inFlight = pending[key] {
            return try await inFlight.value
        }
        let task = Task { try await make() }
        pending[key] = task
        defer { pending[key] = nil }
        let value = try await task.value
        values[key] = value
        return value
    }
}

/// A process-wide, deduplicated cache of open ``IndexStoreSession`` instances.
///
/// Opening an index store (loading `libIndexStore.dylib`, building a temp `IndexStoreDB`,
/// and polling every unit) is expensive. When many index-dependent checkers run
/// concurrently they otherwise each open the **same** store, and those opens serialize.
/// This shares a single read-only session per store path — safe because `IndexStoreDB`
/// is `@unchecked Sendable` (immutable after init; queries are read-only).
public enum SharedIndexStore {

    private static let cache = KeyedAsyncCache<IndexStoreSession>()

    /// Returns a shared session for `storePath`, opening it once across all callers.
    ///
    /// - Parameters:
    ///   - storePath: Path to the index store.
    ///   - libPath: Path to `libIndexStore.dylib`.
    /// - Returns: A shared, ready-to-query ``IndexStoreSession``.
    /// - Throws: If the underlying session cannot be opened.
    public static func session(storePath: URL, libPath: URL) async throws -> IndexStoreSession {
        try await cache.value(for: storePath.path) {
            try IndexStoreSession(storePath: storePath, libPath: libPath)
        }
    }
}
