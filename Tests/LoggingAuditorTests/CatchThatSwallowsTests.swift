import Foundation
import Testing
@testable import LoggingAuditor
@testable import QualityGateCore

/// `logging.catch-without-logging`, after the repair in
/// `plans/proposals/ACatchThatSwallows.md`.
///
/// The rule decided whether a `catch` logged by searching its body text for `".error("` and for
/// each configured logger *name*. `CellValue.error(_:)` spells the same as `Logger.error(_:)`,
/// and `loggerNames` contains the bare string `"log"`, so a body mentioning `catalog` satisfied
/// it too. The rule reported success, which is what it would have reported if it were disabled.
///
/// Every test here fails against that implementation, which is the point: the rule had no test
/// that could fail.
@Suite("catch-without-logging: detection")
struct CatchThatSwallowsDetectionTests {
    private let ruleId = "logging.catch-without-logging"

    private func flagged(_ body: String, errorValueTypes: [String] = []) async throws -> Bool {
        let code = """
        import os
        func foo() -> CellValue {
            do {
                try riskyCall()
            } catch {
                \(body)
            }
        }
        """
        let result = try await TestHelpers.audit(code, errorValueTypes: errorValueTypes)
        return result.diagnostics.contains { $0.ruleId == ruleId }
    }

    // §5.1 — the regression that prompted the proposal.
    @Test("An implicit-member error value is not a logger call")
    func implicitMemberErrorValue() async throws {
        #expect(try await flagged("return .error(.value)"))
    }

    @Test("Result.failure is not a logger call either")
    func resultFailure() async throws {
        #expect(try await flagged("return Result.failure(error)"))
    }

    // The case the proposal did not name: `loggerNames` holds the bare string "log", and the
    // first loop asks `bodyText.contains(name)`. So any word containing "log" passed — and
    // unlike `.error(`, this one needs no error-shaped type to trigger.
    @Test("A word merely containing 'log' is not a logger call")
    func substringLog() async throws {
        #expect(try await flagged("return dialogResult"))
        #expect(try await flagged("return catalog[key]"))
        #expect(try await flagged("return applyLogic(to: input)"))
    }

    @Test("A real logger call is accepted")
    func realLoggerCall() async throws {
        #expect(try await flagged("logger.error(\"failed\"); return .error(.value)") == false)
    }

    @Test("A logger constructed inline is accepted")
    func inlineLoggerCall() async throws {
        #expect(try await flagged(
            "Logger(subsystem: \"x\", category: \"y\").error(\"failed\"); return .error(.value)"
        ) == false)
    }

    @Test("NSLog is accepted")
    func nsLog() async throws {
        #expect(try await flagged("NSLog(\"failed\"); return .error(.value)") == false)
    }

    // §5.6 — a receiver is not enough. It must be a logger.
    @Test("A non-logger receiver with a log-shaped method is not accepted")
    func nonLoggerReceiver() async throws {
        #expect(try await flagged("someValue.log(to: sink); return .error(.value)"))
    }

    // §5.7, §5.8 — `throw` detection moves off substring matching too.
    @Test("'throw' inside a comment is not a throw")
    func throwInComment() async throws {
        #expect(try await flagged("/* throw the dice */ return nil"))
    }

    @Test("'throw' inside a string literal is not a throw")
    func throwInString() async throws {
        #expect(try await flagged("return \"throw \""))
    }

    @Test("A real throw is still accepted")
    func realThrow() async throws {
        #expect(try await flagged("throw error") == false)
    }
}

/// The second half of the proposal: translating an error into a domain value *is* handling it.
///
/// Fixing detection alone turns a rule that found nothing into one that found 55 findings in a
/// single repository, 51 of which are correct code — an Excel function that cannot compute
/// returns `#NUM!`, and the caller receives it. The error did not vanish; it was translated.
///
/// The rule's real subject is an error that *disappears*.
@Suite("catch-without-logging: translation")
struct CatchThatSwallowsTranslationTests {
    private let ruleId = "logging.catch-without-logging"

    private func flagged(_ body: String, errorValueTypes: [String] = []) async throws -> Bool {
        let code = """
        import os
        func foo() -> CellValue {
            do {
                try riskyCall()
            } catch {
                \(body)
            }
        }
        """
        let result = try await TestHelpers.audit(code, errorValueTypes: errorValueTypes)
        return result.diagnostics.contains { $0.ruleId == ruleId }
    }

    @Test("A configured error value is accepted")
    func configuredErrorValue() async throws {
        #expect(try await flagged(
            "return .error(.num)", errorValueTypes: ["CellValue.error"]) == false)
    }

    @Test("nil is still flagged, whatever is configured")
    func nilStillFlagged() async throws {
        #expect(try await flagged("return nil", errorValueTypes: ["CellValue.error"]))
    }

    @Test("A plain zero is still flagged")
    func zeroStillFlagged() async throws {
        #expect(try await flagged("return 0", errorValueTypes: ["CellValue.error"]))
    }

    @Test("An empty body is still flagged")
    func emptyStillFlagged() async throws {
        #expect(try await flagged("", errorValueTypes: ["CellValue.error"]))
    }

    @Test("Every arm of a switch returning an error value is accepted")
    func allArmsTranslate() async throws {
        let body = """
        switch error {
                case CoercionError.type: return .error(.value)
                default: return .error(.num)
                }
        """
        #expect(try await flagged(body, errorValueTypes: ["CellValue.error"]) == false)
    }

    // §5.14 — every exit, not any exit. This is the clause that keeps the carve-out honest.
    @Test("One arm returning nil flags the whole block")
    func oneArmEscapes() async throws {
        let body = """
        if isRecoverable {
                    return .error(.num)
                } else {
                    return nil
                }
        """
        #expect(try await flagged(body, errorValueTypes: ["CellValue.error"]))
    }

    @Test("Translation is not accepted when nothing is configured")
    func defaultIsStrict() async throws {
        #expect(try await flagged("return .error(.num)"))
    }

    @Test("A throw of a configured type still counts as handling")
    func throwOfErrorValue() async throws {
        #expect(try await flagged(
            "throw ExcelError.num", errorValueTypes: ["ExcelError"]) == false)
    }
}

/// The exemption is unchanged and is not the answer to a repeated pattern.
@Suite("catch-without-logging: exemption")
struct CatchThatSwallowsExemptionTests {
    private let ruleId = "logging.catch-without-logging"

    @Test("A logging: comment on the line above suppresses")
    func exemptionComment() async throws {
        let code = """
        import os
        func foo() -> Int? {
            do {
                try riskyCall()
            }
            // logging: converted to a sentinel the caller checks
            catch {
                return nil
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }
}
