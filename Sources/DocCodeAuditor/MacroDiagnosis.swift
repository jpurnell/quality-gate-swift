import Foundation

/// Tells apart the two unrelated causes behind one compiler message.
///
/// ## The message names the wrong thing
///
/// When a macro cannot be expanded, the compiler says:
///
/// ```
/// error: external macro implementation type 'XImpl.FooMacro' could not be found
///        for macro 'Foo()'; plugin for module 'XImpl' not found
/// ```
///
/// *"plugin for module 'XImpl' not found"* is emitted in both of the situations that
/// produce it, and only one of them is about the plugin:
///
/// - **The plugin was never built.** `.build/<config>/XImpl` does not exist. Nothing
///   can load, and the author's macro code is irrelevant to the failure.
/// - **The plugin is built and loaded, but `FooMacro` is not in its
///   `providingMacros`.** The plugin is fine. One line in a list is missing, in a
///   different file from either the macro declaration or the use site, and the
///   compiler's wording points at neither.
///
/// The second is a maintenance failure: it arrives when someone adds a macro and
/// forgets the registration, and the error appears at every *use* site rather than
/// at the declaration. This type reads both sides and says which happened.
///
/// It reports no cause it cannot support. When the plugin is built and the type
/// *is* registered, the answer is that the cause could not be determined — the
/// alternative is inventing a third explanation, which is how a diagnostic starts
/// misdirecting the next person.
public struct MacroDiagnosis: Sendable, Equatable {

    /// The plugin module named in the diagnostic, e.g. `XImpl`.
    public let pluginModule: String

    /// The implementation type the macro declaration points at, e.g. `FooMacro`.
    public let implementationType: String

    /// The macro as written at the use site, e.g. `Foo`.
    public let macroName: String

    /// Creates a diagnosis record.
    public init(pluginModule: String, implementationType: String, macroName: String) {
        self.pluginModule = pluginModule
        self.implementationType = implementationType
        self.macroName = macroName
    }

    /// Recognises the compiler's external-macro diagnostic.
    ///
    /// - Parameter message: A compiler error message.
    /// - Returns: The parts, or `nil` when this is some other error.
    public static func parse(_ message: String) -> MacroDiagnosis? {
        guard message.contains("external macro implementation type") else { return nil }
        guard let qualified = firstQuoted(in: message) else { return nil }
        let parts = qualified.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let module = parts.dropLast().joined(separator: ".")
        let type = String(parts[parts.count - 1])

        var macro = type
        if let range = message.range(of: "for macro '"),
           let end = message[range.upperBound...].firstIndex(of: "'") {
            macro = String(message[range.upperBound..<end])
            if let paren = macro.firstIndex(of: "(") { macro = String(macro[macro.startIndex..<paren]) }
        }
        return MacroDiagnosis(
            pluginModule: module, implementationType: type, macroName: macro)
    }

    /// The first single-quoted run in a message.
    static func firstQuoted(in message: String) -> String? {
        guard let open = message.firstIndex(of: "'") else { return nil }
        let rest = message.index(after: open)
        guard let close = message[rest...].firstIndex(of: "'") else { return nil }
        return String(message[rest..<close])
    }

    /// Names the cause, given what is on disk.
    ///
    /// - Parameters:
    ///   - diagnosis: The parsed diagnostic.
    ///   - pluginWasBuilt: Whether the plugin executable exists in the build directory.
    ///   - registeredTypes: Types the plugin lists in `providingMacros`.
    /// - Returns: A sentence naming the cause, or saying it could not be determined.
    public static func explain(
        _ diagnosis: MacroDiagnosis, pluginWasBuilt: Bool, registeredTypes: [String]
    ) -> String {
        guard pluginWasBuilt else {
            return """
                The macro plugin `\(diagnosis.pluginModule)` was not built, so \
                `@\(diagnosis.macroName)` cannot expand. This is about the build, not about the \
                example: run a build before checking documentation. The compiler's own wording — \
                `plugin for module '\(diagnosis.pluginModule)' not found` — is accurate here.
                """
        }
        guard registeredTypes.contains(diagnosis.implementationType) else {
            let listed = registeredTypes.isEmpty
                ? "nothing"
                : registeredTypes.sorted().joined(separator: ", ")
            return """
                The macro plugin `\(diagnosis.pluginModule)` is built and loaded, but \
                `\(diagnosis.implementationType)` is not in its `providingMacros` — it lists \
                \(listed). The compiler reports this as a missing plugin, which points at the \
                wrong file: the plugin is fine and one line of its registration list is absent. \
                Add `\(diagnosis.implementationType).self` to `providingMacros`.
                """
        }
        return """
            The macro plugin `\(diagnosis.pluginModule)` is built and \
            `\(diagnosis.implementationType)` is registered in its `providingMacros`, so this \
            checker could not determine the cause of `\(diagnosis.macroName)` failing to expand. \
            Reproduce with `swift build` — a cause this checker cannot name is one it will not \
            guess at.
            """
    }

    /// What the package's macro plugins look like on disk, read once per run.
    ///
    /// Package-wide rather than per-target: the question "was this plugin built"
    /// has one answer for the whole run, and reading it per fence would re-walk the
    /// build directory once per doc comment.
    public struct Environment: Sendable, Equatable {

        /// Plugin modules whose executable exists in the build directory.
        public let builtPlugins: Set<String>

        /// Types each plugin registers in `providingMacros`, keyed by plugin module.
        public let registeredByPlugin: [String: [String]]

        /// Creates an environment record.
        public init(builtPlugins: Set<String>, registeredByPlugin: [String: [String]]) {
            self.builtPlugins = builtPlugins
            self.registeredByPlugin = registeredByPlugin
        }

        /// An environment that knows nothing, used when the package cannot be read.
        public static let unknown = Environment(builtPlugins: [], registeredByPlugin: [:])

        /// Reads the package's macro plugins and their registrations.
        ///
        /// - Parameters:
        ///   - projectRoot: The package root.
        ///   - buildDirectory: Where built products live.
        /// - Returns: What is on disk.
        public static func read(projectRoot: URL, buildDirectory: String) -> Environment {
            let manifestURL = projectRoot.appendingPathComponent("Package.swift")
            // silent: no manifest means no macros declared, so the empty environment is correct
            guard let manifest = try? String(contentsOf: manifestURL, encoding: .utf8) else {
                return .unknown
            }
            var built: Set<String> = []
            var registered: [String: [String]] = [:]
            for name in MacroPlugins.macroTargets(in: manifest) {
                let executable = (buildDirectory as NSString).appendingPathComponent(name)
                // SAFETY: CLI tool checks the package's own build directory
                if FileManager.default.fileExists(atPath: executable) { built.insert(name) }
                registered[name] = registrations(ofPlugin: name, projectRoot: projectRoot)
            }
            return Environment(builtPlugins: built, registeredByPlugin: registered)
        }

        /// Every `providingMacros` entry declared anywhere under a plugin's sources.
        static func registrations(ofPlugin name: String, projectRoot: URL) -> [String] {
            var found: Set<String> = []
            for spelling in SourceLayout.spellings {
                let directory = projectRoot
                    .appendingPathComponent(spelling, isDirectory: true)
                    .appendingPathComponent(name, isDirectory: true)
                guard let walker = FileManager.default.enumerator(
                    at: directory, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]) else { continue }
                for case let url as URL in walker where url.pathExtension == "swift" {
                    // silent: an unreadable plugin file contributes no registrations, so no cause is named
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    found.formUnion(registeredTypes(inPluginSource: text))
                }
            }
            return found.sorted()
        }
    }

    /// Names the cause using what the package looks like on disk.
    ///
    /// - Parameters:
    ///   - diagnosis: The parsed diagnostic.
    ///   - environment: The package's macro plugins as read once per run.
    /// - Returns: A sentence naming the cause.
    public static func explain(_ diagnosis: MacroDiagnosis, in environment: Environment) -> String {
        explain(
            diagnosis,
            pluginWasBuilt: environment.builtPlugins.contains(diagnosis.pluginModule),
            registeredTypes: environment.registeredByPlugin[diagnosis.pluginModule] ?? [])
    }

    /// The macro types a plugin registers in `providingMacros`.
    ///
    /// Bracket-matched from the `=`, deliberately. Taking the first `]` after the
    /// property name closes the **type annotation** `[Macro.Type]` and yields an
    /// empty list — which reports every macro in the package as unregistered. That
    /// false positive was produced while measuring this exact class, on a package
    /// whose registrations were complete.
    ///
    /// - Parameter source: Contents of a file declaring a `CompilerPlugin`.
    /// - Returns: Registered type names, sorted.
    public static func registeredTypes(inPluginSource source: String) -> [String] {
        guard let keyword = source.range(of: "providingMacros"),
              let assign = source[keyword.upperBound...].firstIndex(of: "="),
              let open = source[assign...].firstIndex(of: "[") else { return [] }

        var depth = 0
        var end: String.Index?
        var index = open
        while index < source.endIndex {
            if source[index] == "[" { depth += 1 }
            else if source[index] == "]" {
                depth -= 1
                if depth == 0 { end = index; break }
            }
            index = source.index(after: index)
        }
        guard let end else { return [] }

        var names: Set<String> = []
        let body = source[source.index(after: open)..<end]
        var searchStart = body.startIndex
        while let dotSelf = body.range(of: ".self", range: searchStart..<body.endIndex) {
            var nameEnd = dotSelf.lowerBound
            var name = ""
            while nameEnd > body.startIndex {
                let previous = body.index(before: nameEnd)
                let character = body[previous]
                guard character.isLetter || character.isNumber || character == "_" else { break }
                name.insert(character, at: name.startIndex)
                nameEnd = previous
            }
            if !name.isEmpty { names.insert(name) }
            searchStart = dotSelf.upperBound
        }
        return names.sorted()
    }
}
