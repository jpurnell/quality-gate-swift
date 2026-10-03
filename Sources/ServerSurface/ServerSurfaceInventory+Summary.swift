import Foundation

extension ServerSurfaceInventory {

    /// One line saying what was examined, zeros included.
    ///
    /// `examined 4 files · 2 listeners (vapor 1, nio 1) · 1 bound to all interfaces · 1 with
    /// authentication off by default · 3 handlers (vapor 2, nio 1)`. The zeros are printed:
    /// *0 listeners* is how a reader tells "the listener rules passed" from "the listener rules
    /// had nothing to look at", and in most packages it is the second.
    public var summary: String {
        let listeners = productionListeners
        let handlers = productionHandlers
        var parts = [
            "examined \(Self.count(examinedFiles, "file"))",
            Self.count(listeners.count, "listener") + Self.breakdown(listeners.map(\.framework)),
            "\(boundToAllInterfaces.count) bound to all interfaces",
            "\(authenticationOffByDefault.count) with authentication off by default",
            Self.count(handlers.count, "handler") + Self.breakdown(handlers.map(\.framework)),
        ]
        let testListeners = self.listeners.count - listeners.count
        let testHandlers = self.handlers.count - handlers.count
        if testListeners > 0 || testHandlers > 0 {
            parts.append("\(Self.count(testListeners, "listener")) and \(Self.count(testHandlers, "handler")) "
                + "in test targets not counted")
        }
        return parts.joined(separator: " · ")
    }

    /// Production listeners whose address, as far as source decides it, is every interface.
    public var boundToAllInterfaces: [ServerListener] {
        productionListeners.filter { $0.host.kind == .allInterfaces }
    }

    /// Production listeners a caller gets with no authentication unless they add some.
    public var authenticationOffByDefault: [ServerListener] {
        productionListeners.filter {
            switch $0.authentication {
            case .optionalByDefault, .explicitlyNone: return true
            case .environmentSwitch, .notVisible: return false
            }
        }
    }

    private static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    private static func breakdown(_ frameworks: [ServerFramework]) -> String {
        guard !frameworks.isEmpty else { return "" }
        let counts = Dictionary(grouping: frameworks, by: { $0 }).mapValues(\.count)
        let text = counts.keys.sorted().map { "\($0.rawValue) \(counts[$0] ?? 0)" }.joined(separator: ", ")
        return " (\(text))"
    }
}
