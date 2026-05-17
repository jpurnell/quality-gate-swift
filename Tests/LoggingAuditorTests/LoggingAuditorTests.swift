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

// MARK: - Rule 4: missing-privacy

@Suite("LoggingAuditor: missing-privacy")
struct MissingPrivacyTests {
    private let ruleId = "logging.missing-privacy"

    @Test("Flags logger call with interpolation but no privacy annotation")
    func flagsMissingPrivacy() async throws {
        let code = """
        import os
        let logger = Logger(subsystem: "com.app", category: "Test")
        logger.info("Count: \\(items.count)")
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag logger call with privacy annotation")
    func ignoresAnnotated() async throws {
        let code = """
        import os
        let logger = Logger(subsystem: "com.app", category: "Test")
        logger.info("Count: \\(items.count, privacy: .public)")
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag logger call with no interpolation")
    func ignoresPlainString() async throws {
        let code = """
        import os
        let logger = Logger(subsystem: "com.app", category: "Test")
        logger.info("Started processing")
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags when some interpolations annotated and some not")
    func flagsPartialAnnotation() async throws {
        let code = """
        import os
        let logger = Logger(subsystem: "com.app", category: "Test")
        logger.info("\\(a) and \\(b, privacy: .public)")
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag non-logger calls with interpolation")
    func ignoresNonLoggerCalls() async throws {
        let code = """
        import os
        let message = "Count: \\(items.count)"
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags all log levels")
    func flagsAllLevels() async throws {
        let code = """
        import os
        let logger = Logger(subsystem: "com.app", category: "Test")
        logger.debug("\\(x)")
        logger.info("\\(x)")
        logger.notice("\\(x)")
        logger.warning("\\(x)")
        logger.error("\\(x)")
        logger.fault("\\(x)")
        """
        let result = try await TestHelpers.audit(code)
        let count = result.diagnostics.filter { $0.ruleId == ruleId }.count
        #expect(count == 6)
    }

    @Test("Does not flag with logging: exemption comment")
    func respectsExemption() async throws {
        let code = """
        import os
        let logger = Logger(subsystem: "com.app", category: "Test")
        logger.info("\\(items.count)") // logging: privacy not needed for internal tool
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Diagnostic has warning severity")
    func warningSeverity() async throws {
        let code = """
        import os
        let logger = Logger(subsystem: "com.app", category: "Test")
        logger.info("\\(x)")
        """
        let result = try await TestHelpers.audit(code)
        let diag = result.diagnostics.first { $0.ruleId == ruleId }
        #expect(diag?.severity == .warning)
    }
}

// MARK: - Rule 5: bare-logger-init

@Suite("LoggingAuditor: bare-logger-init")
struct BareLoggerInitTests {
    private let ruleId = "logging.bare-logger-init"

    @Test("Flags Logger() with no arguments")
    func flagsBareInit() async throws {
        let code = """
        import os
        let logger = Logger()
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag Logger(subsystem:category:)")
    func ignoresFullInit() async throws {
        let code = """
        import os
        let logger = Logger(subsystem: "com.app", category: "Network")
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag non-Logger types with empty init")
    func ignoresOtherTypes() async throws {
        let code = """
        import os
        let manager = Manager()
        let config = Configuration()
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag with logging: exemption")
    func respectsExemption() async throws {
        let code = """
        import os
        let logger = Logger() // logging: test helper, subsystem not needed
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Diagnostic has info severity")
    func infoSeverity() async throws {
        let code = """
        import os
        let logger = Logger()
        """
        let result = try await TestHelpers.audit(code)
        let diag = result.diagnostics.first { $0.ruleId == ruleId }
        #expect(diag?.severity == .note)
    }
}

// MARK: - Rule 6: catch-without-logging

@Suite("LoggingAuditor: catch-without-logging")
struct CatchWithoutLoggingTests {
    private let ruleId = "logging.catch-without-logging"

    @Test("Flags catch block with no logging and no throw")
    func flagsSilentCatch() async throws {
        let code = """
        import os
        func foo() {
            do {
                try riskyCall()
            } catch {
                return defaultValue
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag catch block that rethrows")
    func ignoresRethrow() async throws {
        let code = """
        import os
        func foo() throws {
            do {
                try riskyCall()
            } catch {
                throw error
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag catch block with logger.error call")
    func ignoresWithLogging() async throws {
        let code = """
        import os
        func foo() {
            do {
                try riskyCall()
            } catch {
                logger.error("failed: \\(error.localizedDescription, privacy: .public)")
                return defaultValue
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag catch block with logger.warning call")
    func ignoresWithWarningLog() async throws {
        let code = """
        import os
        func foo() {
            do {
                try riskyCall()
            } catch {
                logger.warning("degraded: \\(error, privacy: .public)")
                return fallback
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags empty catch block")
    func flagsEmptyCatch() async throws {
        let code = """
        import os
        func foo() {
            do {
                try riskyCall()
            } catch { }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag with logging: exemption")
    func respectsExemption() async throws {
        let code = """
        import os
        func foo() {
            do {
                try riskyCall()
            } catch { // logging: intentionally silent — best-effort cleanup
                return
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Diagnostic has warning severity")
    func warningSeverity() async throws {
        let code = """
        import os
        func foo() {
            do {
                try riskyCall()
            } catch {
                return
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        let diag = result.diagnostics.first { $0.ruleId == ruleId }
        #expect(diag?.severity == .warning)
    }
}

// MARK: - Rule 7: privacy-in-fallback

@Suite("LoggingAuditor: privacy-in-fallback")
struct PrivacyInFallbackTests {
    private let ruleId = "logging.privacy-in-fallback"

    @Test("Flags privacy: annotation inside #else of #if canImport(OSLog)")
    func flagsPrivacyInOSLogElse() async throws {
        let code = """
        #if canImport(OSLog)
        import os
        #else
        struct Logger {
            func error(_ msg: String) {}
        }
        let logger = Logger()
        logger.error("Failed \\(name, privacy: .public)")
        #endif
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags privacy: annotation inside #else of #if canImport(os)")
    func flagsPrivacyInOsElse() async throws {
        let code = """
        #if canImport(os)
        import os
        #else
        struct Logger {
            func error(_ msg: String) {}
        }
        let logger = Logger()
        logger.error("Failed \\(name, privacy: .public)")
        #endif
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag privacy: in the #if canImport(OSLog) branch (Apple side)")
    func allowsPrivacyInAppleBranch() async throws {
        let code = """
        #if canImport(OSLog)
        import os
        let logger = Logger(subsystem: "com.app", category: "Test")
        logger.error("Failed \\(name, privacy: .public)")
        #else
        struct Logger {
            func error(_ msg: String) {}
        }
        #endif
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag logger calls without privacy: in #else (no false positive)")
    func noFalsePositiveInElse() async throws {
        let code = """
        #if canImport(OSLog)
        import os
        #else
        struct Logger {
            func error(_ msg: String) {}
        }
        let logger = Logger()
        logger.error("Failed \\(name)")
        #endif
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Suppresses missing-privacy inside #else fallback block")
    func suppressesMissingPrivacyInFallback() async throws {
        let code = """
        #if canImport(OSLog)
        import os
        #else
        struct Logger {
            func error(_ msg: String) {}
        }
        let logger = Logger()
        logger.error("Failed \\(name)")
        #endif
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "logging.missing-privacy" })
    }

    @Test("Diagnostic has error severity (compile failure on Linux)")
    func errorSeverity() async throws {
        let code = """
        #if canImport(OSLog)
        import os
        #else
        struct Logger {
            func error(_ msg: String) {}
        }
        let logger = Logger()
        logger.error("Failed \\(name, privacy: .public)")
        #endif
        """
        let result = try await TestHelpers.audit(code)
        let diag = result.diagnostics.first { $0.ruleId == ruleId }
        #expect(diag?.severity == .error)
    }

    @Test("Handles nested #if inside #else")
    func handlesNestedIf() async throws {
        let code = """
        #if canImport(OSLog)
        import os
        #else
        #if DEBUG
        struct Logger {
            func error(_ msg: String) {}
        }
        let logger = Logger()
        logger.error("Failed \\(name, privacy: .public)")
        #endif
        #endif
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }
}
