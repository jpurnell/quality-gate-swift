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

    // This fixture was `return Result.failure(error)` until the rule learned to follow the
    // caught error: that body hands the error to the caller inside the `Result`, which is a
    // rethrow in another type, and is accepted now (`CatchThatSurfacesTests`). The point made
    // here is unchanged and needs a body that does not carry it — `.failure(` is no logger.
    @Test("Result.failure is not a logger call either")
    func resultFailure() async throws {
        #expect(try await flagged("return Result.failure(ParseError.unreadable)"))
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

/// The third way an error does not vanish: the caller, or the person at the terminal, gets it.
///
/// The rule accepted a `throw`, a logger call, and a configured error-value type. It could not
/// see a pipe-filter CLI writing the caught error to stderr and exiting non-zero, nor a
/// validation function handing the error back inside its returned message — three sites in
/// SwiftCLIKit, hidden there by a config-wide severity override rather than fixed.
@Suite("catch-without-logging: surfaced to the caller")
struct CatchThatSurfacesTests {
    private let ruleId = "logging.catch-without-logging"

    private func findings(_ code: String) async throws -> [Diagnostic] {
        let result = try await TestHelpers.audit(code, projectType: "cli")
        return result.diagnostics.filter { $0.ruleId == ruleId }
    }

    // MARK: - stderr and exit

    /// SwiftCLIKit `Sources/qg-dashboard/main.swift:22-31`, both clauses.
    @Test("A catch that writes the caught error to stderr and exits is not a swallow")
    func stderrAndExit() async throws {
        let found = try await findings(#"""
            import Foundation
            let checks: [GateCheck]
            do {
                checks = try QualityGateDashboard.checks(fromJSON: StandardInput.readAll())
            } catch let error as StandardInput.ReadError {
                FileHandle.standardError.write(Data("qg-dashboard: could not read stdin — \(error)\n".utf8))
                exit(1)
            } catch {
                FileHandle.standardError.write(Data("qg-dashboard: could not parse quality-gate JSON — \(error)\n".utf8))
                exit(1)
            }
            """#)
        #expect(found.count == 0)
    }

    @Test("Other spellings of 'the error went to stderr'", arguments: [
        #"fputs("failed: \(error)\n", stderr)"#,
        #"print("failed: \(error)", to: &standardError)"#,
        #"FileHandle.standardError.write(Data(error.localizedDescription.utf8))"#,
    ])
    func stderrSpellings(statement: String) async throws {
        let found = try await findings("""
            import Foundation
            func run() {
                do {
                    try riskyCall()
                } catch {
                    \(statement)
                }
            }
            """)
        #expect(found.count == 0, "\(statement)")
    }

    @Test("A catch that prints the caught error and then exits is not a swallow")
    func printedThenExit() async throws {
        let found = try await findings(#"""
            import Foundation
            func run() {
                do {
                    try riskyCall()
                } catch {
                    print("failed: \(error)")
                    exit(1)
                }
            }
            """#)
        #expect(found.count == 0)
    }

    // MARK: - Near misses

    @Test("A fixed string to stderr, and carrying on, is still a swallow")
    func fixedStringAndContinue() async throws {
        let found = try await findings(#"""
            import Foundation
            func run() {
                do {
                    try riskyCall()
                } catch {
                    FileHandle.standardError.write(Data("qg-dashboard: something went wrong\n".utf8))
                }
                finish()
            }
            """#)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 5)
    }

    @Test("A fixed string printed, and carrying on, is still a swallow")
    func printedFixedStringAndContinue() async throws {
        let found = try await findings(#"""
            import Foundation
            func run() {
                do {
                    try riskyCall()
                } catch {
                    print("something went wrong")
                }
                finish()
            }
            """#)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 5)
    }

    @Test("The caught error printed to stdout, and carrying on, is still reported")
    func printedErrorAndContinue() async throws {
        let found = try await findings(#"""
            import Foundation
            func run() {
                do {
                    try riskyCall()
                } catch {
                    print("failed: \(error)")
                }
                finish()
            }
            """#)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 5)
    }

    @Test("Exiting without saying what the error was is still reported")
    func exitWithoutTheError() async throws {
        let found = try await findings(#"""
            import Foundation
            func run() {
                do {
                    try riskyCall()
                } catch {
                    exit(1)
                }
            }
            """#)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 5)
    }

    @Test("An error named in a nested catch does not vouch for the outer one")
    func nestedCatchDoesNotVouch() async throws {
        let found = try await findings(#"""
            import Foundation
            func run() {
                do {
                    try riskyCall()
                } catch {
                    do {
                        try cleanUp()
                    } catch {
                        fputs("cleanup failed: \(error)\n", stderr)
                    }
                }
                finish()
            }
            """#)
        #expect(found.map(\.lineNumber) == [5])
    }

    // MARK: - Translated into the returned value

    /// SwiftCLIKit `Sources/SwiftCLIKit/Widgets/FormValidation.swift:52-62`.
    @Test("A catch whose return carries the caught error is a translation")
    func returnCarriesTheError() async throws {
        let found = try await findings(#"""
            import Foundation
            func validate(_ value: String, regex: String) -> String? {
                do {
                    let expression = try NSRegularExpression(pattern: regex)
                    let range = NSRange(value.startIndex..., in: value)
                    guard expression.firstMatch(in: value, range: range) != nil else {
                        return "Does not match required pattern"
                    }
                    return nil
                } catch {
                    return "Invalid validation pattern: \(error.localizedDescription)"
                }
            }
            """#)
        #expect(found.count == 0)
    }

    @Test("A named binding is the caught error too")
    func namedBinding() async throws {
        let found = try await findings(#"""
            import Foundation
            func load() -> Result<Int, LoadError> {
                do {
                    return .success(try riskyCall())
                } catch let failure as DecodingError {
                    return .failure(.decoding(failure))
                } catch {
                    return .failure(.other(error))
                }
            }
            """#)
        #expect(found.count == 0)
    }

    @Test("Result.failure(error) hands the caught error to the caller")
    func resultFailureCarriesTheError() async throws {
        let found = try await findings(#"""
            import Foundation
            func load() -> Result<Int, Error> {
                do {
                    return .success(try riskyCall())
                } catch {
                    return Result.failure(error)
                }
            }
            """#)
        #expect(found.count == 0)
    }

    @Test("A case or method that is merely called `error` is not the caught error")
    func memberNamedErrorIsNotTheCaughtError() async throws {
        let found = try await findings(#"""
            import Foundation
            func evaluate() -> CellValue {
                do {
                    return try compute()
                } catch {
                    return .error(.value)
                }
            }
            func report() {
                do {
                    try compute()
                } catch {
                    Console.error("failed")
                    exit(1)
                }
            }
            """#)
        #expect(found.map(\.lineNumber) == [5, 12])
    }

    @Test("A return of a default that does not mention the error is still a swallow")
    func returnsDefault() async throws {
        let found = try await findings(#"""
            import Foundation
            func validate(_ value: String, regex: String) -> String? {
                do {
                    _ = try NSRegularExpression(pattern: regex)
                    return nil
                } catch {
                    return "Invalid validation pattern"
                }
            }
            """#)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 6)
    }

    @Test("One exit of several carrying the error is not every exit")
    func onlyOneExitCarriesTheError() async throws {
        let found = try await findings(#"""
            import Foundation
            func validate(_ value: String, regex: String, quiet: Bool) -> String? {
                do {
                    _ = try NSRegularExpression(pattern: regex)
                    return nil
                } catch {
                    if quiet {
                        return nil
                    }
                    return "Invalid validation pattern: \(error.localizedDescription)"
                }
            }
            """#)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 6)
    }

    @Test("A body that can fall off its end has an exit that carries nothing")
    func fallsThrough() async throws {
        let found = try await findings(#"""
            import Foundation
            func validate(_ value: String, regex: String, loud: Bool) -> String? {
                do {
                    _ = try NSRegularExpression(pattern: regex)
                    return nil
                } catch {
                    if loud {
                        return "Invalid validation pattern: \(error.localizedDescription)"
                    }
                }
                return nil
            }
            """#)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 6)
    }

    @Test("A pattern that binds nothing has no error to carry")
    func patternWithoutBinding() async throws {
        let found = try await findings(#"""
            import Foundation
            let error = "unrelated"
            func load() -> String {
                do {
                    return try riskyCall()
                } catch is CancellationError {
                    return "cancelled: \(error)"
                }
            }
            """#)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 6)
    }
}
