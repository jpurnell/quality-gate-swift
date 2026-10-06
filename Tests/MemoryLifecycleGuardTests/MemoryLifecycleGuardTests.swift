import Foundation
import Testing
import SwiftSyntax
import SwiftParser
@testable import MemoryLifecycleGuard
import ConcurrencyAuditor
@testable import QualityGateCore

// MARK: - Test Helper

/// Parses a Swift source string and runs the LifecycleVisitor, returning diagnostics.
func diagnose(
    _ source: String,
    config: MemoryLifecycleConfig = .default
) -> [Diagnostic] {
    let tree = Parser.parse(source: source)
    let visitor = LifecycleVisitor(
        filePath: "test.swift",
        source: source,
        config: config,
        tree: tree
    )
    visitor.walk(tree)
    return visitor.diagnostics
}

// MARK: - Identity Tests

@Suite("MemoryLifecycleGuard: Identity")
struct IdentityTests {
    @Test("Checker id is memory-lifecycle")
    func checkerId() {
        let guard_ = MemoryLifecycleGuard()
        #expect(guard_.id == "memory-lifecycle")
    }

    @Test("Checker name is Memory Lifecycle Guard")
    func checkerName() {
        let guard_ = MemoryLifecycleGuard()
        #expect(guard_.name == "Memory Lifecycle Guard")
    }
}

// MARK: - Task No Deinit Tests

@Suite("MemoryLifecycleGuard: lifecycle-task-no-deinit")
struct TaskNoDeinitTests {
    private let ruleId = "lifecycle-task-no-deinit"

    @Test("Flags class with stored Task property but no deinit")
    func flagsTaskNoDeinit() {
        let code = """
        class Foo {
            var task: Task<Void, Never>?
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Flags class with non-optional Task property but no deinit")
    func flagsNonOptionalTaskNoDeinit() {
        let code = """
        class Foo {
            var task: Task<Void, Error>
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Flags class with implicitly unwrapped Task property but no deinit")
    func flagsImplicitlyUnwrappedTaskNoDeinit() {
        let code = """
        class Foo {
            var task: Task<Void, Never>!
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag class with Task property and deinit")
    func passesTaskWithDeinit() {
        let code = """
        class Foo {
            var task: Task<Void, Never>?
            deinit {
                task?.cancel()
            }
        }
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }
}

// MARK: - Task No Cancel Tests

@Suite("MemoryLifecycleGuard: lifecycle-task-no-cancel")
struct TaskNoCancelTests {
    private let ruleId = "lifecycle-task-no-cancel"

    @Test("Flags class with Task property and deinit that does not call cancel")
    func flagsTaskDeinitNoCancel() {
        let code = """
        class Foo {
            var task: Task<Void, Never>?
            deinit {
                print("bye")
            }
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag class with Task property and deinit calling cancel")
    func passesTaskDeinitWithCancel() {
        let code = """
        class Foo {
            var task: Task<Void, Never>?
            deinit {
                task?.cancel()
            }
        }
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag class with Task property and deinit calling cancel on non-optional")
    func passesNonOptionalTaskDeinitWithCancel() {
        let code = """
        class Foo {
            var task: Task<Void, Never>
            deinit {
                task.cancel()
            }
        }
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }
}

// MARK: - Strong Delegate Tests

@Suite("MemoryLifecycleGuard: lifecycle-strong-delegate")
struct StrongDelegateTests {
    private let ruleId = "lifecycle-strong-delegate"

    @Test("Flags class with strong delegate property")
    func flagsStrongDelegate() {
        let code = """
        class Foo {
            var delegate: SomeDelegate
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag class with weak delegate property")
    func passesWeakDelegate() {
        let code = """
        class Foo {
            weak var delegate: SomeDelegate?
        }
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag class with unowned delegate property")
    func passesUnownedDelegate() {
        let code = """
        class Foo {
            unowned var delegate: SomeDelegate
        }
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId })
    }

    @Test("Flags class with strong parent property")
    func flagsStrongParent() {
        let code = """
        class Foo {
            var parent: ParentVC
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Flags class with strong dataSource property")
    func flagsStrongDataSource() {
        let code = """
        class Foo {
            var dataSource: DS
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Flags class with strong owner property")
    func flagsStrongOwner() {
        let code = """
        class Foo {
            var owner: SomeOwner
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag computed property matching delegate pattern")
    func passesComputedDelegate() {
        let code = """
        class Foo {
            var delegate: SomeDelegate {
                get { return storage }
                set { storage = newValue }
            }
            private var storage: SomeDelegate?
        }
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == ruleId && $0.message.contains("'delegate'") })
    }
}

// MARK: - Actor Exemption Tests

@Suite("MemoryLifecycleGuard: Actor Exemption")
struct ActorExemptionTests {
    @Test("Does not flag actor with Task property and no deinit")
    func actorExemptFromTaskRule() {
        let code = """
        actor Foo {
            var task: Task<Void, Never>?
        }
        """
        let results = diagnose(code)
        #expect(results.isEmpty)
    }

    @Test("Does not flag actor with strong delegate property")
    func actorExemptFromDelegateRule() {
        let code = """
        actor Foo {
            var delegate: SomeDelegate
        }
        """
        let results = diagnose(code)
        #expect(results.isEmpty)
    }
}

// MARK: - Lifecycle Exempt Comment Tests

@Suite("MemoryLifecycleGuard: lifecycle:exempt Comment")
struct LifecycleExemptTests {
    @Test("Does not flag Task property with lifecycle:exempt comment")
    func taskExemptComment() {
        let code = """
        class Foo {
            var task: Task<Void, Never>? // lifecycle:exempt
        }
        """
        let results = diagnose(code)
        #expect(results.isEmpty)
    }

    @Test("Does not flag delegate property with lifecycle:exempt comment")
    func delegateExemptComment() {
        let code = """
        class Foo {
            var delegate: SomeDelegate // lifecycle:exempt
        }
        """
        let results = diagnose(code)
        #expect(results.isEmpty)
    }
}

// MARK: - Configuration Tests

@Suite("MemoryLifecycleGuard: Custom Configuration")
struct ConfigurationTests {
    @Test("Custom delegate patterns are respected")
    func customDelegatePatterns() {
        let config = MemoryLifecycleConfig(
            delegatePatterns: ["handler", "listener"],
            requireTaskCancellation: true,
            exemptFiles: []
        )
        let code = """
        class Foo {
            var handler: SomeHandler
        }
        """
        let results = diagnose(code, config: config)
        #expect(results.contains { $0.ruleId == "lifecycle-strong-delegate" })
    }

    @Test("Default delegate patterns do not match unrelated names")
    func defaultPatternsNoFalsePositive() {
        let code = """
        class Foo {
            var name: String
            var count: Int
        }
        """
        let results = diagnose(code)
        #expect(results.isEmpty)
    }
}

// MARK: - Check Method Tests

@Suite("MemoryLifecycleGuard: check() method")
struct CheckMethodTests {
    /// Scoped to a fixture, for the same reason as `ComplexityAnalyzer`'s advisory test: a
    /// bare `Configuration()` resolves its root to the working directory and scanned this whole
    /// repository, costing 15.7s to reach a conclusion a three-line file settles.
    ///
    /// The assertion was also unfalsifiable. `.passed || .warning` is every status an advisory
    /// checker can return, so it held no matter what the guard did — including doing nothing.
    /// On a fixture known to be clean, `.passed` alone is a claim that can fail.
    @Test("check() passes on a tree with nothing to report")
    func checkPassesClean() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memory-clean-\(UUID().uuidString)")
        let sources = root.appendingPathComponent("Sources/Fixture")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Fixture", targets: [.target(name: "Fixture")])
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        try """
        public struct Clean {
            public let value: Int
            public init(value: Int) { self.value = value }
        }
        """.write(to: sources.appendingPathComponent("Clean.swift"), atomically: true, encoding: .utf8)

        var configuration = Configuration()
        configuration.projectRoot = root
        let result = try await MemoryLifecycleGuard().check(configuration: configuration)

        #expect(result.checkerId == "memory-lifecycle")
        #expect(result.status == .passed)
    }
}

// MARK: - Agreement with ConcurrencyAuditor on `isolated deinit`

/// `lifecycle-task-no-deinit` asks for a deinit; `concurrency.main-actor-deinit-touches-state`
/// reads the deinit that results. These tests pin that following either checker's advice does
/// not walk into the other's finding.
@Suite("MemoryLifecycleGuard: isolated deinit agreement")
struct IsolatedDeinitAgreementTests {
    private let noDeinit = "lifecycle-task-no-deinit"
    private let noCancel = "lifecycle-task-no-cancel"
    private let concurrencyRule = "concurrency.main-actor-deinit-touches-state"

    /// A stored Task and no deinit, with the class attributes supplied by the caller.
    private func storedTaskClass(attributes: String, deinitDecl: String = "") -> String {
        """
        \(attributes)
        final class Monitor {
            var task: Task<Void, Never>?
            \(deinitDecl)
        }
        """
    }

    @Test("An isolated deinit that cancels satisfies both lifecycle rules")
    func isolatedDeinitCountsAsDeinit() {
        let code = storedTaskClass(
            attributes: "@MainActor",
            deinitDecl: "isolated deinit { task?.cancel() }"
        )
        let results = diagnose(code)
        #expect(results.filter { $0.ruleId == noDeinit }.count == 0)
        #expect(results.filter { $0.ruleId == noCancel }.count == 0)
    }

    @Test("On a @MainActor class the suggested deinit is an isolated one")
    func suggestsIsolatedDeinitOnMainActorClass() {
        let isolated = diagnose(storedTaskClass(attributes: "@MainActor"))
            .filter { $0.ruleId == noDeinit }
        #expect(isolated.count == 1)
        #expect(isolated.first?.suggestedFix == "Add an `isolated deinit` that calls task?.cancel().")

        let plain = diagnose(storedTaskClass(attributes: ""))
            .filter { $0.ruleId == noDeinit }
        #expect(plain.count == 1)
        #expect(plain.first?.suggestedFix == "Add a deinit that calls task.cancel().")
    }

    @Test("A non-optional Task handle is cancelled without optional chaining")
    func suggestsPlainCallForNonOptionalHandle() {
        let code = """
        @MainActor
        final class Monitor {
            var task: Task<Void, Never>
            init() { task = Task {} }
        }
        """
        let results = diagnose(code).filter { $0.ruleId == noDeinit }
        #expect(results.count == 1)
        #expect(results.first?.suggestedFix == "Add an `isolated deinit` that calls task.cancel().")
    }

    @Test("Following the lifecycle advice literally leaves both checkers with nothing to say")
    func roundTripProducesNoFindings() async throws {
        // What the advice in `suggestsIsolatedDeinitOnMainActorClass` produces when followed.
        let code = storedTaskClass(
            attributes: "@MainActor",
            deinitDecl: "isolated deinit { task?.cancel() }"
        )
        let lifecycle = diagnose(code)
        #expect(lifecycle.count == 0)

        let concurrency = try await ConcurrencyAuditor()
            .auditSource(code, fileName: "test.swift", configuration: Configuration())
        #expect(concurrency.diagnostics.count == 0)
    }
}
