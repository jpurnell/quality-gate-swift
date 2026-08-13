import Testing
@testable import GPUSafetyAuditor

@Suite("DispatchRules")
struct DispatchRulesTests {

    // MARK: - Rule 2, rounded dispatch

    /// The Validation Trace assertion: the exact idiom from the motivating codebase.
    @Test("Fires on (populationSize + 255) / 256")
    func firesOnRoundedDispatch() {
        let source = """
            func run() {
                let groups = MTLSize(width: (populationSize + 255) / 256, height: 1, depth: 1)
                encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: perGroup)
            }
            """
        let diagnostics = DispatchRules.diagnose(swiftSource: source, path: "GA.swift")
            .filter { $0.ruleId == DispatchRules.roundedDispatchID }
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.severity == .warning)
    }

    /// `dispatchThreads` has no surplus — the driver handles the remainder. Flagging
    /// it would push authors away from the construct that fixes the problem.
    @Test("Stays silent on dispatchThreads")
    func silentOnDispatchThreads() {
        let source = """
            func run() {
                encoder.dispatchThreads(total, threadsPerThreadgroup: perGroup)
            }
            """
        #expect(DispatchRules.diagnose(swiftSource: source, path: "GA.swift")
            .filter { $0.ruleId == DispatchRules.roundedDispatchID }.isEmpty)
    }

    /// An exact division dispatches exactly the elements asked for.
    @Test("Stays silent on an exact division")
    func silentOnExactDivision() {
        let source = """
            func run() {
                let groups = MTLSize(width: count / 256, height: 1, depth: 1)
                encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: perGroup)
            }
            """
        #expect(DispatchRules.diagnose(swiftSource: source, path: "GA.swift")
            .filter { $0.ruleId == DispatchRules.roundedDispatchID }.isEmpty)
    }

    // MARK: - Rule 3, unchecked command buffer

    @Test("Fires when results are read after waitUntilCompleted with no status check")
    func firesOnUncheckedBuffer() {
        let source = """
            func execute() {
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                let output = resultBuffer.contents()
                use(output)
            }
            """
        let diagnostics = DispatchRules.diagnose(swiftSource: source, path: "Device.swift")
            .filter { $0.ruleId == DispatchRules.uncheckedCommandBufferID }
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.severity == .error)
    }

    @Test("Stays silent when status is checked")
    func silentWhenStatusChecked() {
        let source = """
            func execute() throws {
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                guard commandBuffer.status == .completed else { throw GPUError.failed }
                let output = resultBuffer.contents()
                use(output)
            }
            """
        #expect(DispatchRules.diagnose(swiftSource: source, path: "Device.swift")
            .filter { $0.ruleId == DispatchRules.uncheckedCommandBufferID }.isEmpty)
    }

    @Test("Stays silent when error is checked")
    func silentWhenErrorChecked() {
        let source = """
            func execute() throws {
                commandBuffer.waitUntilCompleted()
                if let error = commandBuffer.error { throw error }
                use(resultBuffer.contents())
            }
            """
        #expect(DispatchRules.diagnose(swiftSource: source, path: "Device.swift")
            .filter { $0.ruleId == DispatchRules.uncheckedCommandBufferID }.isEmpty)
    }

    /// A wait in one function and a status check in another is not a check of *this*
    /// dispatch; state must not leak across function boundaries.
    @Test("Completion state does not carry between functions")
    func stateDoesNotLeakAcrossFunctions() {
        let source = """
            func first() {
                commandBuffer.waitUntilCompleted()
            }
            func second() {
                if commandBuffer.status == .completed { use() }
            }
            """
        let diagnostics = DispatchRules.diagnose(swiftSource: source, path: "Device.swift")
            .filter { $0.ruleId == DispatchRules.uncheckedCommandBufferID }
        #expect(diagnostics.count == 1)
    }

    @Test("Diagnostics are ordered by line")
    func orderedByLine() {
        let source = """
            func a() {
                let g = MTLSize(width: (n + 255) / 256, height: 1, depth: 1)
                encoder.dispatchThreadgroups(g, threadsPerThreadgroup: p)
                commandBuffer.waitUntilCompleted()
                use(buffer.contents())
            }
            """
        let lines = DispatchRules.diagnose(swiftSource: source, path: "X.swift")
            .compactMap(\.lineNumber)
        #expect(lines == lines.sorted())
        #expect(lines.count == 2)
    }
}
