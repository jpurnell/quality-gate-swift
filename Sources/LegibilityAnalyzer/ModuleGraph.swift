import Foundation

/// A directed graph of first-party modules and the reference edges between them.
///
/// An edge `A → B` means module `A` references one or more symbols defined in
/// module `B` — i.e. `A` *depends on* `B`. Consequently `B`'s *dependents* (the
/// modules with an edge into `B`) are exactly "what relies on `B`", and a high
/// dependent count marks `B` as load-bearing.
///
/// The type is a pure value with deterministic algorithms — stable node ordering
/// and an iterative (non-recursive) strongly-connected-components pass — so its
/// results are reproducible across runs.
struct ModuleGraph: Sendable, Equatable {

    /// Adjacency: each module mapped to the set of modules it references.
    let edges: [String: Set<String>]

    /// Optional reference weights: `weights[from]?[to]` is the number of distinct
    /// references from `from` into `to`. When an edge exists but has no recorded
    /// weight it counts as `1`, so a weightless graph ranks identically to fan-in.
    let weights: [String: [String: Int]]

    /// Creates a module graph from an adjacency map and optional edge weights.
    init(edges: [String: Set<String>], weights: [String: [String: Int]] = [:]) {
        self.edges = edges
        self.weights = weights
    }

    /// Every module that appears as a source or a target of an edge.
    var modules: Set<String> {
        var all = Set(edges.keys)
        for targets in edges.values {
            all.formUnion(targets)
        }
        return all
    }

    /// Modules that `module` references — its out-edges / dependencies.
    func dependencies(of module: String) -> Set<String> {
        edges[module] ?? []
    }

    /// Modules that reference `module` — its in-edges, i.e. "what relies on it".
    func dependents(of module: String) -> Set<String> {
        var result: Set<String> = []
        for (from, targets) in edges where targets.contains(module) {
            result.insert(from)
        }
        return result
    }

    /// Number of modules that rely on `module` (unweighted fan-in).
    func fanIn(_ module: String) -> Int {
        dependents(of: module).count
    }

    /// Number of modules that `module` relies on (out-degree / fan-out).
    func fanOut(_ module: String) -> Int {
        dependencies(of: module).count
    }

    /// Fan-in weighted by reference counts: the total number of references from
    /// other modules into `module`. Falls back to `1` per edge when no weight is
    /// recorded, so a weightless graph yields the same ranking as ``fanIn(_:)``.
    func weightedFanIn(_ module: String) -> Int {
        var total = 0
        for from in dependents(of: module) {
            total += weights[from]?[module] ?? 1
        }
        return total
    }

    // MARK: - Strongly-connected components

    /// The strongly-connected components of the graph, computed with an iterative
    /// (explicit-stack) Tarjan's algorithm so the pass never recurses.
    ///
    /// Components are returned in reverse-topological order of the condensation:
    /// a component appears *before* every component that depends on it. Because an
    /// edge `A → B` means "A depends on B", the most foundational modules (those
    /// depended upon by many, depending on few) come first — exactly the order in
    /// which a newcomer should read them. Members within a component are ordered
    /// by descending fan-in, then by name, for determinism.
    func stronglyConnectedComponents() -> [[String]] {
        var nextIndex = 0
        var indexOf: [String: Int] = [:]
        var lowLink: [String: Int] = [:]
        var onStack: Set<String> = []
        var tarjanStack: [String] = []
        var components: [[String]] = []

        // Deterministic iteration: sort roots and successors by name.
        for root in modules.sorted() where indexOf[root] == nil {
            // Each frame tracks a node and how many of its successors it has visited.
            var work: [(node: String, next: Int)] = [(root, 0)]

            while let frame = work.last {
                let node = frame.node

                if frame.next == 0 {
                    indexOf[node] = nextIndex
                    lowLink[node] = nextIndex
                    nextIndex += 1
                    tarjanStack.append(node)
                    onStack.insert(node)
                }

                let successors = dependencies(of: node).sorted()

                if frame.next < successors.count {
                    work[work.count - 1].next += 1
                    let successor = successors[frame.next]
                    if indexOf[successor] == nil {
                        work.append((successor, 0))
                    } else if onStack.contains(successor) {
                        let candidate = indexOf[successor] ?? nextIndex
                        lowLink[node] = min(lowLink[node] ?? nextIndex, candidate)
                    }
                    continue
                }

                // All successors of `node` are visited — settle it.
                if (lowLink[node] ?? 0) == (indexOf[node] ?? -1) {
                    var component: [String] = []
                    while let top = tarjanStack.last {
                        tarjanStack.removeLast()
                        onStack.remove(top)
                        component.append(top)
                        if top == node { break }
                    }
                    components.append(orderedByFanIn(component))
                }

                work.removeLast()
                if let parent = work.last {
                    let child = lowLink[node] ?? nextIndex
                    lowLink[parent.node] = min(lowLink[parent.node] ?? nextIndex, child)
                }
            }
        }

        return components
    }

    /// Dependency cycles: strongly-connected components that contain more than one
    /// module, plus any single module with a self-referencing edge. These are the
    /// structures for which no clean reading order exists.
    func cycles() -> [[String]] {
        stronglyConnectedComponents().filter { component in
            if component.count > 1 { return true }
            guard let only = component.first else { return false }
            return dependencies(of: only).contains(only)
        }
    }

    /// A fan-in-weighted reading order over the whole graph: the modules a reader
    /// should study first (most depended-upon, most foundational) come first.
    func topologicalReadingOrder() -> [String] {
        stronglyConnectedComponents().flatMap { $0 }
    }

    /// Orders the members of a component by descending fan-in, then by name.
    private func orderedByFanIn(_ component: [String]) -> [String] {
        component.sorted { lhs, rhs in
            let lhsFanIn = fanIn(lhs)
            let rhsFanIn = fanIn(rhs)
            if lhsFanIn != rhsFanIn { return lhsFanIn > rhsFanIn }
            return lhs < rhs
        }
    }
}
