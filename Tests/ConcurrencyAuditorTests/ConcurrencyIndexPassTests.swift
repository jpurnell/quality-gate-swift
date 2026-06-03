import Foundation
import Testing
@testable import ConcurrencyAuditor
@testable import QualityGateCore

@Suite("ConcurrencyAuditor: Index-backed Pass 2 rules")
struct ConcurrencyIndexPassTests {

    // MARK: - Rule 1: sendable-non-sendable-stored-property (cross-file)

    @Test("Flags stored property added in extension in another file")
    func flagsCrossFileStoredProperty() async throws {
        // Simulate: Type declared Sendable in file A, extension adds
        // a non-Sendable stored property in file B. Pass 1 cannot see this.
        let findings = ConcurrencyIndexPass.analyzeStoredProperties(
            typeName: "MyService",
            declaredFile: "MyService.swift",
            storedProperties: [
                ConcurrencyIndexPass.StoredPropertyInfo(
                    name: "handler",
                    typeName: "(Int) -> Void",
                    isMutable: false,
                    isSendable: false,
                    file: "MyService+Extensions.swift",
                    line: 5
                )
            ]
        )
        #expect(findings.count == 1)
        #expect(findings.first?.ruleId == "concurrency.sendable-non-sendable-stored-property")
        #expect(findings.first?.severity == .warning)
    }

    @Test("Does not flag Sendable-compatible stored properties across files")
    func ignoresSendableProperties() async throws {
        let findings = ConcurrencyIndexPass.analyzeStoredProperties(
            typeName: "MyService",
            declaredFile: "MyService.swift",
            storedProperties: [
                ConcurrencyIndexPass.StoredPropertyInfo(
                    name: "count",
                    typeName: "Int",
                    isMutable: false,
                    isSendable: true,
                    file: "MyService+Extensions.swift",
                    line: 5
                )
            ]
        )
        #expect(findings.isEmpty)
    }

    @Test("Does not flag mutable var already caught by Pass 1 in same file")
    func ignoresSameFileProperties() async throws {
        let findings = ConcurrencyIndexPass.analyzeStoredProperties(
            typeName: "MyService",
            declaredFile: "MyService.swift",
            storedProperties: [
                ConcurrencyIndexPass.StoredPropertyInfo(
                    name: "handler",
                    typeName: "(Int) -> Void",
                    isMutable: false,
                    isSendable: false,
                    file: "MyService.swift",
                    line: 5
                )
            ]
        )
        // Same file -> Pass 1 already handles this; Pass 2 should skip.
        #expect(findings.isEmpty)
    }

    @Test("Flags mutable var in extension file for Sendable class")
    func flagsMutableVarInExtension() async throws {
        let findings = ConcurrencyIndexPass.analyzeStoredProperties(
            typeName: "MyService",
            declaredFile: "MyService.swift",
            storedProperties: [
                ConcurrencyIndexPass.StoredPropertyInfo(
                    name: "cache",
                    typeName: "String",
                    isMutable: true,
                    isSendable: true,
                    file: "MyService+Cache.swift",
                    line: 3
                )
            ]
        )
        #expect(findings.count == 1)
        #expect(findings.first?.ruleId == "concurrency.sendable-non-sendable-stored-property")
    }

    // MARK: - Rule 2: sendable-crosses-isolation

    @Test("Flags unchecked Sendable never sent across isolation boundary")
    func flagsUnnecessaryUncheckedSendable() async throws {
        let findings = ConcurrencyIndexPass.analyzeIsolationCrossings(
            typeName: "CacheManager",
            usageSites: [
                ConcurrencyIndexPass.UsageSite(
                    file: "ViewModel.swift",
                    line: 10,
                    crossesIsolation: false
                ),
                ConcurrencyIndexPass.UsageSite(
                    file: "Service.swift",
                    line: 20,
                    crossesIsolation: false
                )
            ]
        )
        #expect(findings.count == 1)
        #expect(findings.first?.ruleId == "concurrency.sendable-crosses-isolation")
        #expect(findings.first?.severity == .warning)
    }

    @Test("Does not flag unchecked Sendable used across isolation boundary")
    func ignoresCrossIsolationUsage() async throws {
        let findings = ConcurrencyIndexPass.analyzeIsolationCrossings(
            typeName: "CacheManager",
            usageSites: [
                ConcurrencyIndexPass.UsageSite(
                    file: "ViewModel.swift",
                    line: 10,
                    crossesIsolation: false
                ),
                ConcurrencyIndexPass.UsageSite(
                    file: "Service.swift",
                    line: 20,
                    crossesIsolation: true
                )
            ]
        )
        #expect(findings.isEmpty)
    }

    @Test("Does not flag unchecked Sendable with no usage sites")
    func ignoresNoUsageSites() async throws {
        // No usage sites means we cannot prove it is unnecessary.
        let findings = ConcurrencyIndexPass.analyzeIsolationCrossings(
            typeName: "CacheManager",
            usageSites: []
        )
        #expect(findings.isEmpty)
    }

    // MARK: - Rule 3: preconcurrency-import-unnecessary

    @Test("Flags @preconcurrency import when no imported symbol needs it")
    func flagsUnnecessaryPreconcurrencyImport() async throws {
        let findings = ConcurrencyIndexPass.analyzePreconcurrencyImport(
            moduleName: "LegacyLib",
            file: "ViewModel.swift",
            line: 3,
            importedSymbolsUsedInSendableContext: false
        )
        #expect(findings.count == 1)
        #expect(findings.first?.ruleId == "concurrency.preconcurrency-import-unnecessary")
        #expect(findings.first?.severity == .note)
    }

    @Test("Does not flag @preconcurrency import when symbols are used in Sendable context")
    func ignoresNecessaryPreconcurrencyImport() async throws {
        let findings = ConcurrencyIndexPass.analyzePreconcurrencyImport(
            moduleName: "LegacyLib",
            file: "ViewModel.swift",
            line: 3,
            importedSymbolsUsedInSendableContext: true
        )
        #expect(findings.isEmpty)
    }

    // MARK: - Graceful degradation

    @Test("Emits note diagnostic when index store is unavailable")
    func gracefulDegradationWhenNoIndex() async throws {
        let result = ConcurrencyIndexPass.unavailableNote()
        #expect(result.severity == .note)
        #expect(result.ruleId == "concurrency.index-pass.skipped")
    }

    // MARK: - Configuration

    @Test("Config defaults useIndexStore to true")
    func configDefaultsUseIndexStore() {
        let config = ConcurrencyAuditorConfig.default
        #expect(config.useIndexStore == true)
    }

    @Test("Config defaults trackIsolationDepth to false")
    func configDefaultsTrackIsolationDepth() {
        let config = ConcurrencyAuditorConfig.default
        #expect(config.trackIsolationDepth == false)
    }

    @Test("Config decodes useIndexStore from YAML")
    func configDecodesUseIndexStore() throws {
        let yaml = """
        concurrency:
          useIndexStore: false
          trackIsolationDepth: true
        """
        let config = try Configuration.from(yaml: yaml)
        #expect(config.concurrency.useIndexStore == false)
        #expect(config.concurrency.trackIsolationDepth == true)
    }
}
