import Foundation

/// Runs per-article work concurrently, without letting the task group outrun the machine.
///
/// All three rungs need the same thing — typecheck, run, or verify one article at a time,
/// as many at once as there are cores — and each had its own copy of the sliding-window task
/// group. The shape is easy to get subtly wrong (seed the window, refill on completion, not
/// before), and three copies means three places to get it wrong differently.
///
/// The bound is the point. `withTaskGroup` over 73 articles without one would launch 73
/// concurrent `swiftc` invocations, each of which is itself parallel, and the machine would
/// spend its time scheduling rather than compiling.
enum BoundedConcurrency {

    /// Applies `work` to every element, at most `activeProcessorCount` at a time.
    ///
    /// - Parameters:
    ///   - items: The work items.
    ///   - work: What to do with one. Returning `nil` drops that item from the results — the
    ///     rest of the catalogue is still worth processing when one article cannot be read.
    /// - Returns: The non-`nil` results, in completion order. Callers that need a stable
    ///   report sort them, because completion order is a property of the machine.
    static func map<Item: Sendable, Value: Sendable>(
        _ items: [Item], _ work: @escaping @Sendable (Item) -> Value?
    ) async -> [Value] {
        let limit = max(1, ProcessInfo.processInfo.activeProcessorCount)

        return await withTaskGroup(of: Value?.self) { group in
            var next = 0
            while next < min(limit, items.count) {
                let item = items[next]
                group.addTask { work(item) }
                next += 1
            }

            var results: [Value] = []
            while let value = await group.next() {
                if let value { results.append(value) }
                // Refill only as one finishes, so the window stays at `limit` rather than
                // growing to `items.count`.
                if next < items.count {
                    let item = items[next]
                    group.addTask { work(item) }
                    next += 1
                }
            }
            return results
        }
    }
}
