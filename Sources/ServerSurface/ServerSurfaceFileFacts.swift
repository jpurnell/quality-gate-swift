import Foundation
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// What one file contributes to a ``ServerSurfaceInventory``, before the package is joined.
///
/// Opaque on purpose: a caller collects one per file and hands the array to
/// ``ServerSurfaceInventory/init(files:targets:guardTypes:)``. The parts are the rows the file
/// can decide alone and the loose ends only the package can tie — a bind whose host names a
/// parameter declared elsewhere, a `RouteCollection` registered in another file.
public struct ServerSurfaceFileFacts: Sendable {
    /// The file, as named by the caller.
    public let fileName: String

    var listeners: [ServerListener] = []
    var handlers: [PendingHandler] = []
    var hostSettings: [HostSetting] = []
    var authSettings: [AuthSetting] = []
    var registrations: [CollectionRegistration] = []
    var applicationMiddleware: [String] = []
    var mcpTransportAuth: [String] = []
    var declaredTypes: Set<String> = []
    var listenerOwningTypes: Set<String> = []
    var serverHandlerTypes: Set<String> = []
    var channelReads: [(type: String, site: SourceSite)] = []
    var vaporHostnames: [(binding: HostBinding, site: SourceSite)] = []
    var knownListenerAuthOff: [(site: SourceSite, type: String, names: [String])] = []

    init(fileName: String) {
        self.fileName = fileName
    }

    /// Collects one file's facts.
    ///
    /// - Parameters:
    ///   - tree: The parsed file.
    ///   - converter: A converter for `tree`, shared with whatever else walks it.
    ///   - fileName: The name every site will carry.
    /// - Returns: The file's facts.
    public static func collect(
        from tree: SourceFileSyntax,
        converter: SourceLocationConverter,
        fileName: String
    ) -> ServerSurfaceFileFacts {
        let prescan = FilePrescan()
        prescan.walk(tree)
        let collector = ServerSurfaceCollector(fileName: fileName, converter: converter, prescan: prescan)
        collector.walk(tree)
        return collector.facts
    }

    /// Parses `source` and collects its facts. For callers that have text and no tree.
    public static func collect(source: String, fileName: String) -> ServerSurfaceFileFacts {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        return collect(from: tree, converter: converter, fileName: fileName)
    }
}

/// A handler row and, for a route inside `boot(routes:)`, the collection whose registration
/// decides its lineage and prefix.
struct PendingHandler: Sendable {
    var row: ServerHandler
    /// The `RouteCollection` whose registration decides lineage and prefix.
    var collection: String?
    /// Group path components between the root and the route.
    var prefix: [String] = []
    /// The route's own path components; empty for a row whose route is already final.
    var components: [String] = []
    /// Group arguments that are not paths, unclassified until the guard list is known.
    var lineage: [String] = []
    /// The handler body calls `req.auth.require(…)`.
    var requiresInHandler = false
    /// Vapor rows get their path and auth at assembly; others are final when collected.
    var isVaporRoute: Bool { row.framework == .vapor }

    init(row: ServerHandler, collection: String? = nil) {
        self.row = row
        self.collection = collection
    }
}

/// `register(collection: T())` on a routes-shaped receiver.
struct CollectionRegistration: Sendable {
    var typeName: String
    var prefix: [String]
    var lineage: [String]
    var site: SourceSite
    /// Where the receiver came from — a collection registered inside another collection's
    /// `boot(routes:)` inherits that one's registration in turn.
    var root: RouteContext.Root
}

