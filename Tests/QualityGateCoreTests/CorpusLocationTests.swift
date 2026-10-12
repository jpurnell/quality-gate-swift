import Testing
import Foundation
@testable import QualityGateCore

/// Where the corpus is, decided once — and the three ways the answer can be "nowhere usable".
///
/// Every reader and writer of the corpus goes through ``CorpusLocation``, so a value the
/// gate should not act on cannot reach `CorpusPath(basePath:)` from any of them.
@Suite("CorpusLocation")
struct CorpusLocationTests {

    private let root = URL(fileURLWithPath: "/work/BusinessMathExcel", isDirectory: true)

    /// A probe that fails the test if it is consulted: most cases must not need git at all.
    private static let unconsulted: GitIgnoreProbe.Check = { _, _ in
        Issue.record("git was consulted for a path that could not be inside the repository")
        return .undetermined
    }

    private static func answering(_ answer: GitIgnoreAnswer) -> GitIgnoreProbe.Check {
        { _, _ in answer }
    }

    // MARK: - Resolution

    @Test("no corpusPath is unconfigured, and asks git nothing")
    func absentIsUnconfigured() {
        #expect(CorpusLocation.resolve(
            configured: nil, projectRoot: root, gitIgnore: Self.unconsulted) == .unconfigured)
    }

    @Test("an absolute path is used as written, wherever it points")
    func absoluteIsUsable() {
        let corpus = "/Users/jpurnell/Dropbox/Computer/Development/Swift/Tools/org-judgement-corpus"
        #expect(CorpusLocation.resolve(
            configured: corpus, projectRoot: root, gitIgnore: Self.unconsulted)
            == .usable(path: corpus))
    }

    @Test("an absolute path inside the repository is the author's explicit choice")
    func absoluteInsideRepositoryIsUsable() {
        #expect(CorpusLocation.resolve(
            configured: "/work/BusinessMathExcel/corpus", projectRoot: root,
            gitIgnore: Self.unconsulted)
            == .usable(path: "/work/BusinessMathExcel/corpus"))
    }

    @Test("a relative path resolves against the project root, not the process directory")
    func relativeResolvesAgainstProjectRoot() {
        #expect(CorpusLocation.resolve(
            configured: "../org-judgement-corpus", projectRoot: root,
            gitIgnore: Self.unconsulted)
            == .usable(path: "/work/org-judgement-corpus"))
    }

    // MARK: - Refusals

    @Test("the value that started this never becomes a location")
    func shellReferenceIsRejected() {
        #expect(CorpusLocation.resolve(
            configured: "${ORG_JUDGEMENT_CORPUS:-}", projectRoot: root,
            gitIgnore: Self.unconsulted)
            == .rejected(.invalidValue(ConfigPathProblem(
                key: "consistency.corpusPath",
                value: "${ORG_JUDGEMENT_CORPUS:-}",
                reason: .shellReference("${ORG_JUDGEMENT_CORPUS:-}")))))
    }

    @Test("an empty value is rejected rather than resolving to the repository itself")
    func emptyIsRejected() {
        #expect(CorpusLocation.resolve(
            configured: "", projectRoot: root, gitIgnore: Self.unconsulted)
            == .rejected(.invalidValue(ConfigPathProblem(
                key: "consistency.corpusPath", value: "", reason: .empty))))
    }

    @Test("a relative path inside the repository that git does not ignore is rejected")
    func relativeInsideUnignoredIsRejected() {
        #expect(CorpusLocation.resolve(
            configured: "corpus", projectRoot: root, gitIgnore: Self.answering(.notIgnored))
            == .rejected(.insideRepository(
                value: "corpus",
                path: "/work/BusinessMathExcel/corpus",
                repositoryRoot: "/work/BusinessMathExcel")))
    }

    @Test("the repository root itself is inside the repository")
    func dotIsInsideRepository() {
        #expect(CorpusLocation.resolve(
            configured: ".", projectRoot: root, gitIgnore: Self.answering(.notIgnored))
            == .rejected(.insideRepository(
                value: ".",
                path: "/work/BusinessMathExcel",
                repositoryRoot: "/work/BusinessMathExcel")))
    }

    @Test("a relative path inside the repository that git ignores is a local corpus")
    func relativeInsideIgnoredIsUsable() {
        #expect(CorpusLocation.resolve(
            configured: ".ijs-corpus", projectRoot: root, gitIgnore: Self.answering(.ignored))
            == .usable(path: "/work/BusinessMathExcel/.ijs-corpus"))
    }

    @Test("where git cannot answer there is no working tree to dirty, so the path stands")
    func undeterminedIsUsable() {
        #expect(CorpusLocation.resolve(
            configured: ".ijs-corpus", projectRoot: root, gitIgnore: Self.answering(.undetermined))
            == .usable(path: "/work/BusinessMathExcel/.ijs-corpus"))
    }

    @Test("git is asked about a file the gate would write, not about the directory")
    func gitIsAskedAboutAFileBeneathTheCorpus() {
        // Asked about `corpus` alone, a `corpus/` ignore rule does not match while the
        // directory does not exist yet — which is exactly the first run.
        // The probe answers "ignored" for exactly that question and nothing else, so the
        // result is `.usable` only if that is what was asked.
        let location = CorpusLocation.resolve(
            configured: "corpus", projectRoot: root,
            gitIgnore: { path, repositoryRoot in
                let expected = path == "/work/BusinessMathExcel/corpus/telemetry/probe.json"
                    && repositoryRoot == "/work/BusinessMathExcel"
                return expected ? .ignored : .notIgnored
            })
        #expect(location == .usable(path: "/work/BusinessMathExcel/corpus"))
    }

    @Test("a sibling whose name merely starts with the repository's is outside it")
    func siblingWithSharedPrefixIsOutside() {
        #expect(CorpusLocation.resolve(
            configured: "../BusinessMathExcel-corpus", projectRoot: root,
            gitIgnore: Self.unconsulted)
            == .usable(path: "/work/BusinessMathExcel-corpus"))
    }

    // MARK: - Messages

    @Test("the containment message names the value, where it lands, and both fixes")
    func containmentMessage() {
        let problem = CorpusLocationProblem.insideRepository(
            value: "corpus",
            path: "/work/BusinessMathExcel/corpus",
            repositoryRoot: "/work/BusinessMathExcel")
        #expect(problem.message == """
            `consistency.corpusPath` is set to `corpus`, which resolves to \
            /work/BusinessMathExcel/corpus — inside the repository being checked \
            (/work/BusinessMathExcel), where git does not ignore it. Every run would write \
            telemetry into the working tree as untracked files. Point it at the corpus outside \
            this repository, or add it to `.gitignore` if a local corpus is intended.
            """)
    }

    @Test("an invalid value's message is the path rule's own message")
    func invalidValueMessageIsTheRuleMessage() {
        let rule = ConfigPathProblem(
            key: "consistency.corpusPath", value: "~/corpus", reason: .homeShorthand)
        #expect(CorpusLocationProblem.invalidValue(rule).message == rule.message)
    }

    // MARK: - Configuration

    @Test("Configuration resolves its own corpus against its own root")
    func configurationResolvesItsCorpus() {
        var configuration = Configuration(
            consistency: ConsistencyCheckerConfig(corpusPath: "../org-judgement-corpus"))
        configuration.projectRoot = root
        #expect(configuration.corpusLocation(gitIgnore: Self.unconsulted)
            == .usable(path: "/work/org-judgement-corpus"))
    }

    @Test("configuration errors list every path problem, then containment, each once")
    func configurationErrorsAreListedOnce() {
        var configuration = Configuration(
            vendorPaths: ["~/vendor"],
            consistency: ConsistencyCheckerConfig(corpusPath: "${ORG_JUDGEMENT_CORPUS:-}"))
        configuration.projectRoot = root
        #expect(configuration.pathConfigurationErrors(gitIgnore: Self.unconsulted) == [
            ConfigPathProblem(
                key: "vendorPaths[0]", value: "~/vendor", reason: .homeShorthand).message,
            ConfigPathProblem(
                key: "consistency.corpusPath",
                value: "${ORG_JUDGEMENT_CORPUS:-}",
                reason: .shellReference("${ORG_JUDGEMENT_CORPUS:-}")).message,
        ])

        var contained = Configuration(consistency: ConsistencyCheckerConfig(corpusPath: "corpus"))
        contained.projectRoot = root
        #expect(contained.pathConfigurationErrors(gitIgnore: Self.answering(.notIgnored)) == [
            CorpusLocationProblem.insideRepository(
                value: "corpus",
                path: "/work/BusinessMathExcel/corpus",
                repositoryRoot: "/work/BusinessMathExcel").message,
        ])
    }

    @Test("a healthy configuration has no path configuration errors")
    func healthyConfigurationHasNoErrors() {
        var configuration = Configuration(consistency: ConsistencyCheckerConfig(
            corpusPath: "/Users/jpurnell/Dropbox/Computer/Development/Swift/Tools/org-judgement-corpus"))
        configuration.projectRoot = root
        #expect(configuration.pathConfigurationErrors(gitIgnore: Self.unconsulted) == [])
    }

    // MARK: - The real probe

    @Test("the real probe distinguishes ignored, not ignored, and no repository")
    func realProbeAgainstARealRepository() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qg-gitignore-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let repository = base.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) } // silent: temp fixture cleanup

        // No `GIT_*`: inside a hook they point at the outer repository.
        let environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        let initialised = try ProcessRunner.run(
            "/usr/bin/git", arguments: ["init", "-q"], currentDirectory: repository.path,
            environment: environment, timeout: 60)
        #expect(initialised.exitCode == 0)
        try ".ijs-corpus/\n".write(
            to: repository.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

        #expect(GitIgnoreProbe.check(
            repository.appendingPathComponent(".ijs-corpus/telemetry/probe.json").path,
            repository.path) == .ignored)
        #expect(GitIgnoreProbe.check(
            repository.appendingPathComponent("corpus/telemetry/probe.json").path,
            repository.path) == .notIgnored)
        #expect(GitIgnoreProbe.check(
            "/nonexistent-\(UUID().uuidString)/telemetry/probe.json",
            "/nonexistent-\(UUID().uuidString)") == .undetermined)
    }
}
