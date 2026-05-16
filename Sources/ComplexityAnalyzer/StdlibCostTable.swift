/// Built-in cost table for Swift standard library operations.
///
/// Maps method names to their known Big-O costs. Only includes operations
/// whose algorithmic guarantees are documented by Apple and stable across versions.
enum StdlibCostTable {

    /// Known O(n) operations (linear scan).
    static let linearOperations: Set<String> = [
        "contains",
        "first",
        "firstIndex",
        "last",
        "lastIndex",
        "min",
        "max",
        "filter",
        "map",
        "flatMap",
        "compactMap",
        "reduce",
        "forEach",
        "allSatisfy",
        "contains(where:)",
        "first(where:)",
        "firstIndex(where:)",
        "removeAll(where:)",
        "prefix(while:)",
        "drop(while:)",
    ]

    /// Known O(n log n) operations.
    static let logLinearOperations: Set<String> = [
        "sort",
        "sorted",
        "sorted(by:)",
        "sort(by:)",
    ]

    /// Known O(1) operations (constant time).
    static let constantOperations: Set<String> = [
        "append",
        "removeLast",
        "isEmpty",
        "count",
        "first",
        "last",
        "subscript",
    ]

    /// Returns the known cost for a method name, or nil if unknown.
    static func cost(for methodName: String) -> String? {
        let baseName = methodName.split(separator: "(").first.map(String.init) ?? methodName
        if logLinearOperations.contains(baseName) || logLinearOperations.contains(methodName) {
            return "O(n log n)"
        }
        if linearOperations.contains(baseName) || linearOperations.contains(methodName) {
            return "O(n)"
        }
        if constantOperations.contains(baseName) || constantOperations.contains(methodName) {
            return "O(1)"
        }
        return nil
    }

    /// Whether a method is a linear search (O(n) lookup on a collection).
    static func isLinearSearch(_ methodName: String) -> Bool {
        let searches: Set<String> = ["contains", "first", "firstIndex", "contains(where:)", "first(where:)", "firstIndex(where:)"]
        let baseName = methodName.split(separator: "(").first.map(String.init) ?? methodName
        return searches.contains(baseName) || searches.contains(methodName)
    }

    /// Whether a method is a sort operation.
    static func isSortOperation(_ methodName: String) -> Bool {
        let baseName = methodName.split(separator: "(").first.map(String.init) ?? methodName
        return logLinearOperations.contains(baseName) || logLinearOperations.contains(methodName)
    }
}
