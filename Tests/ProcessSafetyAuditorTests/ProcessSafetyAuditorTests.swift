import Testing
@testable import ProcessSafetyAuditor

@Suite("ProcessSafetyAuditor")
struct ProcessSafetyAuditorTests {
    let auditor = ProcessSafetyAuditor()

    @Test("Detects waitUntilExit before readDataToEndOfFile")
    func detectsDeadlockPattern() {
        let source = """
        import Foundation
        func runProcess() {
            let process = Process()
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
        }
        """
        let diags = auditor.auditSource(source, fileName: "Test.swift")
        #expect(diags.count == 1)
        #expect(diags.first?.ruleId == "process.wait-before-read")
    }

    @Test("Passes when readDataToEndOfFile comes before waitUntilExit")
    func passesCorrectOrder() {
        let source = """
        import Foundation
        func runProcess() {
            let process = Process()
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
        }
        """
        let diags = auditor.auditSource(source, fileName: "Test.swift")
        #expect(diags.isEmpty)
    }

    @Test("Detects deadlock with separate stdout and stderr pipes")
    func detectsTwoPipeDeadlock() {
        let source = """
        import Foundation
        func runProcess() {
            let process = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            try process.run()
            process.waitUntilExit()
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        }
        """
        let diags = auditor.auditSource(source, fileName: "Test.swift")
        #expect(diags.count == 1)
    }

    @Test("Passes when no pipe reading occurs")
    func passesNoPipeReading() {
        let source = """
        import Foundation
        func runProcess() {
            let process = Process()
            try process.run()
            process.waitUntilExit()
        }
        """
        let diags = auditor.auditSource(source, fileName: "Test.swift")
        #expect(diags.isEmpty)
    }

    @Test("Passes when no waitUntilExit occurs")
    func passesNoWait() {
        let source = """
        import Foundation
        func runProcess() {
            let process = Process()
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
        }
        """
        let diags = auditor.auditSource(source, fileName: "Test.swift")
        #expect(diags.isEmpty)
    }

    @Test("Respects process-safety:disable comment")
    func respectsDisableComment() {
        let source = """
        import Foundation
        func runProcess() {
            let process = Process()
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit() // process-safety:disable output is always small
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
        }
        """
        let diags = auditor.auditSource(source, fileName: "Test.swift")
        #expect(diags.isEmpty)
    }

    @Test("Detects pattern inside closures")
    func detectsInClosure() {
        let source = """
        import Foundation
        let work = {
            let process = Process()
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
        }
        """
        let diags = auditor.auditSource(source, fileName: "Test.swift")
        #expect(diags.count == 1)
    }

    @Test("Empty source produces no diagnostics")
    func emptySource() {
        let diags = auditor.auditSource("", fileName: "Empty.swift")
        #expect(diags.isEmpty)
    }
}
