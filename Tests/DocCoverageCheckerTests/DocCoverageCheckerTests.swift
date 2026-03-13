import Testing
@testable import DocCoverageChecker
@testable import QualityGateCore

/// Tests for DocCoverageChecker.
///
/// DocCoverageChecker uses SwiftSyntax to find public APIs
/// without documentation comments.
@Suite("DocCoverageChecker Tests")
struct DocCoverageCheckerTests {

    // MARK: - Identity Tests

    @Test("DocCoverageChecker has correct id and name")
    func checkerIdentity() {
        let checker = DocCoverageChecker()
        #expect(checker.id == "doc-coverage")
        #expect(checker.name == "Documentation Coverage")
    }

    // MARK: - Fully Documented Code Tests

    @Test("No diagnostics for fully documented code")
    func fullyDocumentedCode() async throws {
        let source = """
        /// A well-documented struct.
        public struct MyType {
            /// The value property.
            public var value: Int

            /// Creates a new instance.
            public init(value: Int) {
                self.value = value
            }

            /// Does something important.
            public func doSomething() {}
        }
        """

        let result = try await checkSource(source)
        #expect(result.status == .passed)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("No diagnostics for internal code without docs")
    func internalCodeIgnored() async throws {
        let source = """
        // Internal code doesn't need docs
        struct InternalType {
            var value: Int
            func doSomething() {}
        }

        func helperFunction() {}
        """

        let result = try await checkSource(source)
        #expect(result.status == .passed)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("No diagnostics for private code without docs")
    func privateCodeIgnored() async throws {
        let source = """
        private struct PrivateType {
            private var value: Int
            private func doSomething() {}
        }
        """

        let result = try await checkSource(source)
        #expect(result.status == .passed)
        #expect(result.diagnostics.isEmpty)
    }

    // MARK: - Undocumented Public API Tests

    @Test("Detects undocumented public function")
    func undocumentedPublicFunction() async throws {
        let source = """
        public func undocumentedFunction() {}
        """

        let result = try await checkSource(source)
        #expect(result.status == .failed)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.ruleId == "missing-doc")
        #expect(result.diagnostics.first?.message.contains("undocumentedFunction") == true)
    }

    @Test("Detects undocumented public struct")
    func undocumentedPublicStruct() async throws {
        let source = """
        public struct UndocumentedStruct {
            /// This property is documented.
            public var value: Int
        }
        """

        let result = try await checkSource(source)
        #expect(result.status == .failed)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.message.contains("UndocumentedStruct") == true)
    }

    @Test("Detects undocumented public class")
    func undocumentedPublicClass() async throws {
        let source = """
        public class UndocumentedClass {}
        """

        let result = try await checkSource(source)
        #expect(result.status == .failed)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.message.contains("UndocumentedClass") == true)
    }

    @Test("Detects undocumented public enum")
    func undocumentedPublicEnum() async throws {
        let source = """
        public enum UndocumentedEnum {
            case one
            case two
        }
        """

        let result = try await checkSource(source)
        #expect(result.status == .failed)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.message.contains("UndocumentedEnum") == true)
    }

    @Test("Detects undocumented public protocol")
    func undocumentedPublicProtocol() async throws {
        let source = """
        public protocol UndocumentedProtocol {
            func requiredMethod()
        }
        """

        let result = try await checkSource(source)
        #expect(result.status == .failed)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.message.contains("UndocumentedProtocol") == true)
    }

    @Test("Detects undocumented public property")
    func undocumentedPublicProperty() async throws {
        let source = """
        /// A documented struct.
        public struct MyStruct {
            public var undocumentedProperty: Int
        }
        """

        let result = try await checkSource(source)
        #expect(result.status == .failed)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.message.contains("undocumentedProperty") == true)
    }

    @Test("Detects undocumented public initializer")
    func undocumentedPublicInit() async throws {
        let source = """
        /// A documented struct.
        public struct MyStruct {
            public init() {}
        }
        """

        let result = try await checkSource(source)
        #expect(result.status == .failed)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.message.contains("init") == true)
    }

    @Test("Detects undocumented public typealias")
    func undocumentedPublicTypealias() async throws {
        let source = """
        public typealias MyAlias = Int
        """

        let result = try await checkSource(source)
        #expect(result.status == .failed)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.message.contains("MyAlias") == true)
    }

    // MARK: - Multiple Undocumented APIs

    @Test("Detects multiple undocumented APIs")
    func multipleUndocumented() async throws {
        let source = """
        public struct UndocStruct {}
        public func undocFunc() {}
        public var undocVar: Int = 0
        """

        let result = try await checkSource(source)
        #expect(result.status == .failed)
        #expect(result.diagnostics.count == 3)
    }

    // MARK: - Edge Cases

    @Test("Handles empty source")
    func emptySource() async throws {
        let result = try await checkSource("")
        #expect(result.status == .passed)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Documentation with only summary is sufficient")
    func singleLineDocIsSufficient() async throws {
        let source = """
        /// Brief documentation.
        public func documentedFunction() {}
        """

        let result = try await checkSource(source)
        #expect(result.status == .passed)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Multi-line documentation is recognized")
    func multiLineDocRecognized() async throws {
        let source = """
        /// Brief summary.
        ///
        /// Detailed description here.
        /// - Parameter x: The input.
        /// - Returns: The output.
        public func documentedFunction(x: Int) -> Int { x }
        """

        let result = try await checkSource(source)
        #expect(result.status == .passed)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Block comments are not documentation")
    func blockCommentsNotDocs() async throws {
        let source = """
        /* This is not documentation */
        public func notDocumented() {}
        """

        let result = try await checkSource(source)
        #expect(result.status == .failed)
        #expect(result.diagnostics.count == 1)
    }

    @Test("Regular comments are not documentation")
    func regularCommentsNotDocs() async throws {
        let source = """
        // This is not documentation
        public func notDocumented() {}
        """

        let result = try await checkSource(source)
        #expect(result.status == .failed)
        #expect(result.diagnostics.count == 1)
    }

    @Test("Diagnostics include line numbers")
    func diagnosticsIncludeLineNumbers() async throws {
        let source = """
        import Foundation

        public func undocumented() {}
        """

        let result = try await checkSource(source)
        #expect(result.diagnostics.first?.line == 3)
    }

    @Test("Respects exclude patterns")
    func respectsExcludePatterns() async throws {
        let checker = DocCoverageChecker()
        let config = Configuration(excludePatterns: ["**/Generated/**"])

        // This tests the pattern matching logic
        #expect(checker.shouldExclude(path: "/path/to/Generated/File.swift", patterns: config.excludePatterns))
        #expect(!checker.shouldExclude(path: "/path/to/Sources/File.swift", patterns: config.excludePatterns))
    }

    // MARK: - Helpers

    private func checkSource(_ source: String) async throws -> CheckResult {
        let checker = DocCoverageChecker()
        return try await checker.checkSource(
            source,
            fileName: "test.swift",
            configuration: Configuration()
        )
    }
}
