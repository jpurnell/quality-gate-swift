import Foundation

// Internal types whose witness methods (`hash(into:)`, `==`, `encode(to:)`)
// are exercised only via stdlib protocol machinery — the index typically
// doesn't record those references, so the v5 well-known-witness allow-list
// must keep them alive.

struct InternalHashable: Hashable {
    let id: Int
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: InternalHashable, rhs: InternalHashable) -> Bool {
        lhs.id == rhs.id
    }
}

struct InternalCodableThing: Codable {
    let value: Int
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.value = try c.decode(Int.self)
    }
    init(value: Int) { self.value = value }
}

// Public reachable consumer so the types themselves are not dead.
public func makeWitnesses() -> Int {
    let s: Set<InternalHashable> = [InternalHashable(id: 1)]
    let c = InternalCodableThing(value: 2)
    let data = (try? JSONEncoder().encode(c)) ?? Data()
    return s.count + data.count
}
