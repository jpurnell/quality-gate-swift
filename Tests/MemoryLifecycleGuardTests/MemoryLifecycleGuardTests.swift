import Foundation
import Testing
import SwiftSyntax
import SwiftParser
@testable import MemoryLifecycleGuard
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
    @Test("check() returns passed status when no issues found")
    func checkPassesClean() async throws {
        let guard_ = MemoryLifecycleGuard()
        let result = try await guard_.check(configuration: Configuration())
        #expect(result.checkerId == "memory-lifecycle")
        #expect(result.status == .passed || result.status == .warning)
    }
}
