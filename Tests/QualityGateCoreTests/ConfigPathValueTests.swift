import Testing
import Foundation
@testable import QualityGateCore

/// A path written in `.quality-gate.yml` is used as written — nothing expands it.
///
/// Two repositories carried `corpusPath: ${ORG_JUDGEMENT_CORPUS:-}` for three weeks. The
/// gate created a directory with that literal name inside each checkout, wrote every run's
/// telemetry into it, and `consistency` reported a skip as a pass because the "corpus" it
/// found there had no pulse. These tests pin the rule that ends it: a value that only a
/// shell could have resolved is refused by name, in one place, for every path-valued key.
@Suite("ConfigPathValue")
struct ConfigPathValueTests {

    // MARK: - The rule

    @Test("the value that started this is refused, and the reference is named exactly")
    func theOriginalValueIsRefused() {
        let problem = ConfigPathValue.problem(
            key: "consistency.corpusPath", value: "${ORG_JUDGEMENT_CORPUS:-}")
        #expect(problem == ConfigPathProblem(
            key: "consistency.corpusPath",
            value: "${ORG_JUDGEMENT_CORPUS:-}",
            reason: .shellReference("${ORG_JUDGEMENT_CORPUS:-}")))
    }

    @Test("every shell-style spelling is recognised", arguments: [
        ("$HOME/corpus", "$HOME"),
        ("${HOME}/corpus", "${HOME}"),
        ("${CORPUS:-/tmp/corpus}", "${CORPUS:-/tmp/corpus}"),
        ("/data/$USER/corpus", "$USER"),
        ("prefix-${A}-${B}", "${A}"),
        ("$(pwd)/corpus", "$(pwd)"),
        ("$_private", "$_private"),
        ("${UNTERMINATED", "${UNTERMINATED"),
    ])
    func shellReferencesAreRecognised(value: String, reference: String) {
        let problem = ConfigPathValue.problem(key: "status.guidelinesPath", value: value)
        #expect(problem?.reason == .shellReference(reference))
        #expect(problem?.key == "status.guidelinesPath")
        #expect(problem?.value == value)
    }

    @Test("a leading tilde is refused: a shell expands it, the gate does not", arguments: [
        "~", "~/corpus", "~jpurnell/corpus",
    ])
    func leadingTildeIsRefused(value: String) {
        #expect(ConfigPathValue.problem(key: "consistency.corpusPath", value: value)
            == ConfigPathProblem(key: "consistency.corpusPath", value: value, reason: .homeShorthand))
    }

    @Test("an empty or blank value is refused rather than read as the current directory",
          arguments: ["", " ", "\t"])
    func emptyIsRefused(value: String) {
        #expect(ConfigPathValue.problem(key: "consistency.corpusPath", value: value)
            == ConfigPathProblem(key: "consistency.corpusPath", value: value, reason: .empty))
    }

    @Test("ordinary paths and globs are accepted", arguments: [
        "/Users/jpurnell/Dropbox/Computer/Development/Swift/Tools/org-judgement-corpus",
        "../org-judgement-corpus",
        ".ijs-corpus",
        ".",
        "project/master_plan.md",
        "Sources/**/Generated/*.swift",
        "file~backup",
        "cost-in-$",
        "price$",
        "a$1b",
    ])
    func ordinaryValuesAreAccepted(value: String) {
        #expect(ConfigPathValue.problem(key: "vendorPaths", value: value) == nil)
    }

    // MARK: - The message

    @Test("the message names the key, the value, the reference and the fix")
    func messageNamesKeyValueAndFix() {
        let problem = ConfigPathProblem(
            key: "consistency.corpusPath",
            value: "${ORG_JUDGEMENT_CORPUS:-}",
            reason: .shellReference("${ORG_JUDGEMENT_CORPUS:-}"))
        #expect(problem.message == """
            `consistency.corpusPath` is set to `${ORG_JUDGEMENT_CORPUS:-}`, and \
            `${ORG_JUDGEMENT_CORPUS:-}` is shell syntax. The gate does not expand environment \
            variables in `.quality-gate.yml`: used as written, this names a directory literally \
            called `${ORG_JUDGEMENT_CORPUS:-}`. Write the path itself, absolute or relative to \
            the repository root.
            """)
    }

    @Test("the tilde message says what to write instead")
    func tildeMessage() {
        let problem = ConfigPathProblem(
            key: "legibility.artifactPath", value: "~/artifacts", reason: .homeShorthand)
        #expect(problem.message == """
            `legibility.artifactPath` is set to `~/artifacts`, and a leading `~` is shell \
            shorthand. The gate does not expand it: used as written, this names a directory \
            literally called `~`. Write the path itself, absolute or relative to the \
            repository root.
            """)
    }

    @Test("the empty message says to remove the key or fill it in")
    func emptyMessage() {
        let problem = ConfigPathProblem(key: "consistency.corpusPath", value: "", reason: .empty)
        #expect(problem.message == """
            `consistency.corpusPath` is set to an empty value. An empty path is not a location. \
            Remove the key to leave it unset, or write the path.
            """)
    }

    // MARK: - Every path-valued key, in one place

    @Test("the file that started this decodes, and reports exactly one problem")
    func theOriginalFileReportsOneProblem() throws {
        let configuration = try Configuration.from(yaml: """
            consistency:
              corpusPath: ${ORG_JUDGEMENT_CORPUS:-}   # set in the environment; no absolute path in the repo
              projectID: BusinessMathExcel
            status:
              guidelinesPath: "."
              masterPlanPath: project/master_plan.md
            """)
        #expect(configuration.pathValueProblems == [
            ConfigPathProblem(
                key: "consistency.corpusPath",
                value: "${ORG_JUDGEMENT_CORPUS:-}",
                reason: .shellReference("${ORG_JUDGEMENT_CORPUS:-}")),
        ])
    }

    @Test("a default configuration has no path problems")
    func defaultsAreClean() {
        #expect(Configuration().pathValueProblems == [])
    }

    @Test("the healthy portfolio's shapes have no path problems")
    func healthyShapesAreClean() throws {
        let configuration = try Configuration.from(yaml: """
            vendorPaths:
              - Vendor/
            consistency:
              corpusPath: /Users/jpurnell/Dropbox/Computer/Development/Swift/Tools/org-judgement-corpus
            ijs:
              corpusPath: "../org-judgement-corpus"
            status:
              guidelinesPath: "."
              masterPlanPath: ../quality-gate-swift-project/master_plan.md
            boundedIO:
              kernelPath: Sources/ProcessKernel
            """)
        #expect(configuration.pathValueProblems == [])
    }

    @Test("the same rule reaches every path-valued key", arguments: [
        ("vendorPaths:\n  - $VENDOR\n", "vendorPaths[0]"),
        ("consistency:\n  corpusPath: $X\n", "consistency.corpusPath"),
        ("ijs:\n  corpusPath: $X\n", "ijs.corpusPath"),
        ("status:\n  guidelinesPath: $X\n", "status.guidelinesPath"),
        ("status:\n  masterPlanPath: $X\n", "status.masterPlanPath"),
        ("memoryBuilder:\n  guidelinesPath: $X\n", "memoryBuilder.guidelinesPath"),
        ("releaseReadiness:\n  changelogPath: $X\n", "releaseReadiness.changelogPath"),
        ("releaseReadiness:\n  readmePath: $X\n", "releaseReadiness.readmePath"),
        ("boundedIO:\n  kernelPath: $X\n", "boundedIO.kernelPath"),
        ("legibility:\n  artifactPath: $X\n", "legibility.artifactPath"),
        ("xcodeBuild:\n  project: $X\n", "xcodeBuild.project"),
        ("xcodeBuild:\n  workspace: $X\n", "xcodeBuild.workspace"),
        ("doc-code:\n  moduleSearchPath: $X\n", "doc-code.moduleSearchPath"),
        ("doc-code:\n  headerSearchPaths:\n    - ok\n    - $X\n", "doc-code.headerSearchPaths[1]"),
        ("doc-code:\n  librarySearchPaths:\n    - $X\n", "doc-code.librarySearchPaths[0]"),
        ("doc-generated:\n  additionalFiles:\n    - $X\n", "doc-generated.additionalFiles[0]"),
        ("mcpReadiness:\n  additionalPaths:\n    - $X\n", "mcpReadiness.additionalPaths[0]"),
        ("mcpReadiness:\n  excludePaths:\n    - $X\n", "mcpReadiness.excludePaths[0]"),
        ("appIntentsReadiness:\n  excludePaths:\n    - $X\n", "appIntentsReadiness.excludePaths[0]"),
        ("plugins:\n  - name: demo\n    run: $X\n", "plugins[0].run"),
        ("excludePatterns:\n  - $X\n", "excludePatterns[0]"),
        ("fpSafety:\n  allowedFiles:\n    - $X\n", "fpSafety.allowedFiles[0]"),
        ("stochasticDeterminism:\n  exemptFiles:\n    - $X\n", "stochasticDeterminism.exemptFiles[0]"),
        ("memoryLifecycle:\n  exemptFiles:\n    - $X\n", "memoryLifecycle.exemptFiles[0]"),
    ])
    func everyPathKeyIsCovered(yaml: String, key: String) throws {
        let configuration = try Configuration.from(yaml: yaml)
        #expect(configuration.pathValueProblems.map(\.key) == [key])
    }

    @Test("a CLI override is judged by the same rule as the file")
    func overrideIsJudgedToo() {
        let configuration = Configuration().applying(
            CLIOverrides(telemetryCorpusPath: "${ORG_JUDGEMENT_CORPUS:-}"))
        #expect(configuration.pathValueProblems.map(\.key) == ["consistency.corpusPath"])
    }
}
