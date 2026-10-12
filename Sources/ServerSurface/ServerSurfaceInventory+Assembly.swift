import Foundation
import QualityGateCore

extension ServerSurfaceInventory {

    /// Joins per-file facts into the package's inventory.
    ///
    /// The result is independent of the order `files` arrive in: they are sorted by name first,
    /// and every row list is sorted by site.
    ///
    /// - Parameters:
    ///   - files: One ``ServerSurfaceFileFacts`` per examined file, in any order.
    ///   - targets: The package's targets, to say which target a row belongs to and whether it
    ///     is a test target. Empty puts everything in the anonymous target.
    ///   - guardTypes: Middleware type names the project declares as guards
    ///     (`AHandlerSaysWhoMayCallIt.md` §3.2). Empty by default: a name heuristic would count
    ///     `UserAuthenticator` and be wrong in the direction that matters.
    ///   - dependencies: The text of the package's `Package.swift` and `Package.resolved`, to
    ///     say which release of a library its rows are read with. ``PackageDependencies/unknown``
    ///     by default, which leaves the calls themselves to decide and otherwise assumes the
    ///     current release — and says it assumed.
    public init(
        files: [ServerSurfaceFileFacts],
        targets: TargetTypeMap = TargetTypeMap(targets: []),
        guardTypes: Set<String> = [],
        dependencies: PackageDependencies = .unknown
    ) {
        let assembly = Assembly(files: files.sorted { $0.fileName < $1.fileName }, targets: targets,
                                guardTypes: guardTypes, dependencies: dependencies)
        self = assembly.build()
    }

    /// Parses and joins `sources`. For tests and tools that hold text rather than trees.
    public static func build(
        sources: [(path: String, source: String)],
        targets: TargetTypeMap = TargetTypeMap(targets: []),
        guardTypes: Set<String> = [],
        dependencies: PackageDependencies = .unknown
    ) -> ServerSurfaceInventory {
        ServerSurfaceInventory(
            files: sources.map { ServerSurfaceFileFacts.collect(source: $0.source, fileName: $0.path) },
            targets: targets,
            guardTypes: guardTypes,
            dependencies: dependencies)
    }

    /// Sets `column` on the handler registered at `site`.
    ///
    /// The extension point for the columns later proposals add: a rule that knows a body
    /// ceiling or a credential kind for a handler finds it by the site it already reported and
    /// writes its cell. Rows are not reshaped and no other rule's columns are touched.
    ///
    /// - Returns: Whether a handler was registered at `site`.
    @discardableResult
    public mutating func setColumn(_ column: ServerSurfaceColumn, to value: ColumnValue, forHandlerAt site: SourceSite) -> Bool {
        guard let index = handlers.firstIndex(where: { $0.site == site }) else { return false }
        handlers[index].columns[column] = value
        return true
    }

    /// Sets `column` on the listener opened at `site`. See ``setColumn(_:to:forHandlerAt:)``.
    @discardableResult
    public mutating func setColumn(_ column: ServerSurfaceColumn, to value: ColumnValue, forListenerAt site: SourceSite) -> Bool {
        guard let index = listeners.firstIndex(where: { $0.site == site }) else { return false }
        listeners[index].columns[column] = value
        return true
    }
}

/// The join, step by step.
private struct Assembly {
    let files: [ServerSurfaceFileFacts]
    let targets: TargetTypeMap
    let guardTypes: Set<String>
    let dependencies: PackageDependencies
    let declaredTypes: Set<String>

    init(files: [ServerSurfaceFileFacts], targets: TargetTypeMap, guardTypes: Set<String>,
         dependencies: PackageDependencies) {
        self.files = files
        self.targets = targets
        self.guardTypes = guardTypes
        self.dependencies = dependencies
        self.declaredTypes = files.reduce(into: Set<String>()) { $0.formUnion($1.declaredTypes) }
    }

    /// The target `file` belongs to, and whether it is a test target.
    func owner(of file: String) -> (name: String?, isTest: Bool) {
        guard let target = targets.target(forFile: file) else { return (nil, false) }
        return (target.name, target.type == "test")
    }

    func targetKey(_ name: String?) -> String { name ?? ServerSurfaceInventory.anonymousTarget }

    func build() -> ServerSurfaceInventory {
        let hostSettings = files.flatMap(\.hostSettings).map(placed).sorted { $0.site < $1.site }
        var listeners = files.flatMap(\.listeners).filter(isOwnListener).map(placed)
        let owningTypes = Set(listeners.compactMap { $0.framework.opensOwnSocket ? $0.owningType : nil })
        let authSettings = files.flatMap(\.authSettings).map(placed)
            .filter { $0.kind != .argument || isAuthCarrier($0.callee, owningTypes: owningTypes) }
            .sorted { $0.site < $1.site }
        let vaporHost = files.flatMap(\.vaporHostnames).sorted { $0.site < $1.site }.first?.binding
        let release = mcpRelease(listeners)
        for index in listeners.indices {
            if let release, isMCPListener(listeners[index]) {
                listeners[index].host = mcpHost(listeners[index], release: release)
            }
            listeners[index].host = resolvedHost(listeners[index], hostSettings: hostSettings, vaporHost: vaporHost)
            listeners[index].authentication = authentication(of: listeners[index], settings: authSettings)
        }
        listeners.sort { $0.site < $1.site }
        let listenerTargets = Set(listeners.filter { !$0.inTestTarget }.map { targetKey($0.target) })
        return ServerSurfaceInventory(
            listeners: listeners,
            handlers: handlers().sorted { $0.site < $1.site },
            hostSettings: hostSettings,
            authSettings: authSettings,
            examinedFiles: files.count,
            listenerOwningTypes: owningTypes,
            listenerTargets: listenerTargets,
            libraries: release.map { [$0] } ?? [])
    }

    // MARK: - SwiftMCPServer's two generations

    /// A listener the SwiftMCPServer library opens for this package.
    func isMCPListener(_ listener: ServerListener) -> Bool {
        listener.construct == ServerSurfaceVocabulary.mcpBuilderConstruct
            || listener.construct == ServerSurfaceVocabulary.mcpTransportConstruct
    }

    /// Which release of SwiftMCPServer the package's listeners are read with, or `nil` when it
    /// has none.
    ///
    /// What the package declares decides: a manifest requirement that admits one major, then
    /// the pin. Where neither says — a `path:` dependency, a source audited alone — the calls
    /// are evidence: `authenticator:` and `oauthServer:` on the transport exist only before
    /// 5.0.0, and `host:`, `listen(host:)` and `authentication` only from it. Where the calls
    /// do not say either, or say both, the current release is assumed and recorded as assumed.
    func mcpRelease(_ listeners: [ServerListener]) -> LibraryRelease? {
        guard listeners.contains(where: isMCPListener) else { return nil }
        let library = ServerSurfaceVocabulary.swiftMCPServer
        if let declared = dependencies.release(of: library) { return declared }
        let current = LibraryRelease.swiftMCPServerLoopbackMajor
        let shapes = files.reduce(into: Set<Int>()) { $0.formUnion($1.mcpReleaseShapes) }
        if shapes == [current - 1] {
            return LibraryRelease(library: library, major: current - 1, evidence: .apiShape,
                                  detail: ServerSurfaceVocabulary.fourShapeDetail)
        }
        if shapes == [current] {
            return LibraryRelease(library: library, major: current, evidence: .apiShape,
                                  detail: ServerSurfaceVocabulary.fiveShapeDetail)
        }
        return LibraryRelease(library: library, major: current, evidence: .assumed,
                              detail: ServerSurfaceVocabulary.assumedDetail)
    }

    /// Where a SwiftMCPServer listener binds, given the release.
    ///
    /// The collector records the current release's default. Before 5.0.0 a listener with no
    /// address in source is the library's own `0.0.0.0`, which the caller cannot narrow; from
    /// 5.0.0 a builder binds what `listen(host:)` says, when the chain says it.
    func mcpHost(_ listener: ServerListener, release: LibraryRelease) -> HostBinding {
        let isBuilder = listener.construct == ServerSurfaceVocabulary.mcpBuilderConstruct
        guard release.bindsLoopbackByDefault else {
            guard case .frameworkDefault = listener.host else { return listener.host }
            let note = isBuilder
                ? ServerSurfaceVocabulary.builderNote(loopbackByDefault: false)
                : ServerSurfaceVocabulary.transportNote(loopbackByDefault: false)
            return .inherited(library: release.library, kind: .allInterfaces, note: note)
        }
        guard isBuilder else { return listener.host }
        let said = scoped(files.flatMap(\.mcpListenHosts), to: listener, site: \.site)
            .sorted { $0.site < $1.site }
        // Two `listen(host:)` calls are two branches: the wider one is what can happen.
        let widest = said.first { $0.binding.kind == .allInterfaces } ?? said.first
        return widest?.binding ?? listener.host
    }

    /// The entries written in `listener`'s file, or failing that in its target: a builder is
    /// usually one chain, and sometimes a binding configured by a helper beside it.
    func scoped<Entry>(_ entries: [Entry], to listener: ServerListener, site: KeyPath<Entry, SourceSite>) -> [Entry] {
        let sameFile = entries.filter { $0[keyPath: site].file == listener.site.file }
        guard sameFile.isEmpty else { return sameFile }
        return entries.filter { targetKey(owner(of: $0[keyPath: site].file).name) == targetKey(listener.target) }
    }

    // MARK: - Placement

    func placed(_ listener: ServerListener) -> ServerListener {
        var row = listener
        (row.target, row.inTestTarget) = owner(of: listener.site.file)
        return row
    }

    func placed(_ setting: HostSetting) -> HostSetting {
        var row = setting
        (row.target, row.inTestTarget) = owner(of: setting.site.file)
        return row
    }

    func placed(_ setting: AuthSetting) -> AuthSetting {
        var row = setting
        (row.target, row.inTestTarget) = owner(of: setting.site.file)
        return row
    }

    /// A library listener constructed inside the library that declares it is not a second
    /// listener: the library's own bind is already a row.
    func isOwnListener(_ listener: ServerListener) -> Bool {
        if listener.construct == "MCPServer.builder" { return !declaredTypes.contains("MCPServerBuilder") }
        if ServerSurfaceVocabulary.knownListenerTypes[listener.construct] != nil {
            return !declaredTypes.contains(listener.construct)
        }
        return true
    }

    func isAuthCarrier(_ callee: String?, owningTypes: Set<String>) -> Bool {
        guard let callee else { return false }
        return ServerSurfaceVocabulary.knownAuthCarriers.contains(callee) || owningTypes.contains(callee)
    }

    // MARK: - Listener resolution

    /// A bind expression naming a parameter or property of the owning type takes that
    /// declaration's literal default; a Vapor application takes an assigned hostname.
    func resolvedHost(_ listener: ServerListener, hostSettings: [HostSetting], vaporHost: HostBinding?) -> HostBinding {
        if listener.framework == .vapor, let vaporHost { return vaporHost }
        guard case .expression(let text, nil) = listener.host, let owner = listener.owningType else {
            return listener.host
        }
        let name = text.hasPrefix("self.") ? String(text.dropFirst(5)) : text
        let declared = hostSettings.first {
            ($0.kind == .parameterDefault || $0.kind == .propertyDefault)
                && $0.owningType == owner && $0.name == name
        }
        guard let declared else { return listener.host }
        return .expression(text, defaultValue: HostDefault(value: declared.value, kind: declared.addressKind, site: declared.site))
    }

    /// What decides authentication for `listener`: whatever leaves it open first — an explicit
    /// "none", a default that is off, an environment switch — and only then an authenticator
    /// written where the listener is made.
    func authentication(of listener: ServerListener, settings: [AuthSetting]) -> ListenerAuthentication {
        let known = files.flatMap(\.knownListenerAuth).first { $0.site == listener.site }
        let onBuilder = listener.construct == ServerSurfaceVocabulary.mcpBuilderConstruct
            ? scoped(files.flatMap(\.mcpBuilderAuth), to: listener, site: \.site).sorted { $0.site < $1.site }
            : []
        let off = (known?.off ?? []) + onBuilder.filter { !$0.enforced }.map(\.name)
        if !off.isEmpty { return .explicitlyNone(names: unique(off)) }
        let enforced = (known?.by ?? []) + onBuilder.filter(\.enforced).map(\.name)
        let sameTarget = settings.filter { targetKey($0.target) == targetKey(listener.target) }
        let defaults = sameTarget.filter { $0.kind == .parameterDefault || $0.kind == .propertyDefault }
        if !defaults.isEmpty { return .optionalByDefault(names: unique(defaults.flatMap(\.names))) }
        let switches = sameTarget.filter { $0.kind == .environmentFlag }
        if !switches.isEmpty { return .environmentSwitch(keys: unique(switches.compactMap(\.environmentKey))) }
        if !enforced.isEmpty { return .authenticated(by: unique(enforced)) }
        return .notVisible
    }

    // MARK: - Handlers

    func handlers() -> [ServerHandler] {
        let transport = unique(files.flatMap(\.mcpTransportAuth))
        let installed = files.reduce(into: Set<String>()) { $0.formUnion($1.serverHandlerTypes) }
        var rows: [ServerHandler] = []
        for file in files {
            for pending in file.handlers {
                var row = pending.isVaporRoute ? vaporRow(pending) : pending.row
                (row.target, row.inTestTarget) = owner(of: row.site.file)
                if row.framework == .swiftMCPServer, row.kind != .mcpHTTPRoute { row.auth.transport = transport }
                if row.framework == .vapor { row.auth.applicationMiddleware = applicationMiddleware(for: row.target) }
                rows.append(row)
            }
            for read in file.channelReads where installed.contains(read.type) {
                var row = ServerHandler(site: read.site, framework: .nio, kind: .channelHandler, method: nil, route: read.type)
                (row.target, row.inTestTarget) = owner(of: read.site.file)
                rows.append(row)
            }
        }
        return rows
    }

    func applicationMiddleware(for target: String?) -> [String] {
        files.filter { targetKey(owner(of: $0.fileName).name) == targetKey(target) }
            .flatMap(\.applicationMiddleware)
    }

    /// A Vapor route's path and auth, with a collection's registration joined in.
    func vaporRow(_ pending: PendingHandler) -> ServerHandler {
        var row = pending.row
        var prefix = pending.prefix
        var lineage = pending.lineage
        if let collection = pending.collection {
            let resolution = resolve(collection: collection, depth: 0)
            prefix = resolution.prefix + prefix
            lineage = resolution.lineage + lineage
            row.auth.lineageKnown = resolution.known
            row.auth.otherRegistrations = resolution.others
        }
        let path = (prefix + pending.components).joined(separator: "/")
        row.route = "/" + path
        classify(lineage, into: &row.auth)
        row.auth.requiresInHandler = pending.requiresInHandler
        return row
    }

    /// Where a collection is registered. Two registrations: the weaker lineage, and the other
    /// site named. None: unknown. Recursive through collections registered inside another
    /// collection's `boot`; `depth` ends a cycle.
    func resolve(collection: String, depth: Int) -> (prefix: [String], lineage: [String], known: Bool, others: [SourceSite]) {
        let registrations = files.flatMap(\.registrations).filter { $0.typeName == collection }
            .sorted { $0.site < $1.site }
        guard depth < 4, let weakest = registrations.min(by: { guardCount($0.lineage) < guardCount($1.lineage) }) else {
            return ([], [], false, [])
        }
        var prefix = weakest.prefix
        var lineage = weakest.lineage
        var known = true
        if case .collection(let outer) = weakest.root {
            let parent = resolve(collection: outer, depth: depth + 1)
            prefix = parent.prefix + prefix
            lineage = parent.lineage + lineage
            known = parent.known
        }
        let others = registrations.filter { $0.site != weakest.site }.map(\.site)
        return (prefix, lineage, known, others)
    }

    func guardCount(_ lineage: [String]) -> Int {
        var auth = HandlerAuth()
        classify(lineage, into: &auth)
        return auth.guards.count
    }

    /// Sorts lineage elements into guards, authenticators and other middleware
    /// (`AHandlerSaysWhoMayCallIt.md` §3.2).
    func classify(_ lineage: [String], into auth: inout HandlerAuth) {
        for element in lineage {
            let typeName = String(element.prefix { $0 != "(" && $0 != "." })
            if element.contains("guardMiddleware(") || element.contains("redirectMiddleware(")
                || guardTypes.contains(typeName) {
                auth.guards.append(element)
            } else if element.lowercased().contains("authenticator") {
                auth.authenticators.append(element)
            } else {
                auth.middleware.append(element)
            }
        }
    }

    func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
