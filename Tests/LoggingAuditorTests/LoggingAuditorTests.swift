import Foundation
import Testing
@testable import LoggingAuditor
@testable import QualityGateCore

// MARK: - Identity

@Suite("LoggingAuditor: Identity")
struct LoggingAuditorIdentityTests {

    @Test("LoggingAuditor has correct id and name")
    func identity() {
        let auditor = LoggingAuditor()
        #expect(auditor.id == "logging")
        #expect(auditor.name == "Logging Auditor")
    }
}

// MARK: - Project Type Gate

@Suite("LoggingAuditor: Project Type")
struct ProjectTypeTests {

    @Test("Skips when projectType is library")
    func skipsLibrary() async throws {
        let code = """
        print("hello")
        """
        let result = try await TestHelpers.audit(code, projectType: "library")
        #expect(result.status == .skipped)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Runs when projectType is application")
    func runsApplication() async throws {
        let code = """
        print("hello")
        """
        let result = try await TestHelpers.audit(code, projectType: "application")
        #expect(result.status != .skipped)
    }
}

// MARK: - Rule 1: print-statement

@Suite("LoggingAuditor: print-statement")
struct PrintStatementTests {
    private let ruleId = "logging.print-statement"

    @Test("Flags bare print() call")
    func flagsPrint() async throws {
        let code = """
        func foo() {
            print("hello world")
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
        #expect(result.status == .failed)
    }

    @Test("Flags debugPrint() call")
    func flagsDebugPrint() async throws {
        let code = """
        func foo() {
            debugPrint(someValue)
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags print with interpolation")
    func flagsPrintWithInterpolation() async throws {
        let code = """
        let x = 42
        print("value: \\(x)")
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag print with // logging: exemption on same line")
    func ignoresLoggingExemptionSameLine() async throws {
        let code = """
        print("temporary debug") // logging: needed for beta diagnostics
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag print with // logging: exemption on previous line")
    func ignoresLoggingExemptionPrevLine() async throws {
        let code = """
        // logging: temporary for beta
        print("debug info")
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag method call like logger.print()")
    func ignoresMethodCallPrint() async throws {
        let code = """
        import os
        let printer = Printer()
        printer.print(document)
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Diagnostic has error severity")
    func errorSeverity() async throws {
        let code = """
        print("x")
        """
        let result = try await TestHelpers.audit(code)
        let diag = result.diagnostics.first { $0.ruleId == ruleId }
        #expect(diag?.severity == .error)
    }
}

// MARK: - Rule 2: silent-try

@Suite("LoggingAuditor: silent-try")
struct SilentTryTests {
    private let ruleId = "logging.silent-try"

    @Test("Flags try? without logging")
    func flagsSilentTry() async throws {
        let code = """
        import os
        func foo() {
            let x = try? riskyCall()
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag try? with adjacent logger call")
    func ignoresWithAdjacentLogging() async throws {
        let code = """
        import os
        func foo() {
            logger.error("risky call failed")
            let x = try? riskyCall()
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag try? with // silent: comment")
    func ignoresWithSilentComment() async throws {
        let code = """
        import os
        let x = try? riskyCall() // silent: expected to fail on first launch
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag try? await Task.sleep")
    func ignoresTaskSleep() async throws {
        let code = """
        import os
        try? await Task.sleep(for: .milliseconds(100))
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag try? JSONEncoder")
    func ignoresJSONEncoder() async throws {
        let code = """
        import os
        let data = try? JSONEncoder().encode(value)
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag try? JSONDecoder")
    func ignoresJSONDecoder() async throws {
        let code = """
        import os
        let obj = try? JSONDecoder().decode(Foo.self, from: data)
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag regular try (no question mark)")
    func ignoresRegularTry() async throws {
        let code = """
        import os
        let x = try riskyCall()
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag try! (force try is a different rule)")
    func ignoresForceTry() async throws {
        let code = """
        import os
        let x = try! riskyCall()
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Recognizes custom logger names for adjacency")
    func recognizesCustomLoggerNames() async throws {
        let code = """
        import os
        NarbisLog.persistence.error("failed")
        let x = try? riskyCall()
        """
        let result = try await TestHelpers.audit(code, customLoggerNames: ["NarbisLog"])
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Diagnostic has warning severity")
    func warningSeverity() async throws {
        let code = """
        import os
        let x = try? riskyCall()
        """
        let result = try await TestHelpers.audit(code)
        let diag = result.diagnostics.first { $0.ruleId == ruleId }
        #expect(diag?.severity == .warning)
    }

    @Test("Respects custom silentTryKeyword")
    func customKeyword() async throws {
        let code = """
        import os
        let x = try? riskyCall() // safe: fire-and-forget
        """
        let result = try await TestHelpers.audit(code, silentTryKeyword: "safe:")
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }
}

// MARK: - Rule 3: no-os-logger-import

@Suite("LoggingAuditor: no-os-logger-import")
struct NoOSLoggerImportTests {
    private let ruleId = "logging.no-os-logger-import"

    @Test("Flags file with print but no import os")
    func flagsPrintNoImport() async throws {
        let code = """
        import Foundation
        print("hello")
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag file with import os")
    func ignoresWithImportOS() async throws {
        let code = """
        import os
        print("hello")
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag clean file with no logging calls")
    func ignoresCleanFile() async throws {
        let code = """
        import Foundation
        func foo() -> Int { 42 }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Diagnostic has warning severity")
    func warningSeverity() async throws {
        let code = """
        print("x")
        """
        let result = try await TestHelpers.audit(code)
        let diag = result.diagnostics.first { $0.ruleId == ruleId }
        #expect(diag?.severity == .warning)
    }
}
