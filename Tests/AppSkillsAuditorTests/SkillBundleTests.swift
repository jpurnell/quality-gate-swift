import Foundation
import Testing
@testable import AppSkillsAuditor
import QualityGateCore

/// Apple's skills bundle fails silently: a bundle with one wrong folder name is not rejected,
/// it is simply not offered to Siri. These rules turn each silent failure into a finding.
/// See `OneReadinessManyCarriers.md` §4.5.
@Suite("AppSkillsAuditor — bundle structure")
struct SkillBundleTests {

    private func findings(_ fixture: SkillsFixture, rule: String) -> [Diagnostic] {
        SkillsAudit.analyze(root: fixture.root).filter { $0.ruleId == rule }
    }

    private func bundle(_ skills: [String: String], name: String = "Skills.skillsbundle") -> [String: String] {
        Dictionary(uniqueKeysWithValues: skills.map { ("\(name)/\($0.key)", $0.value) })
    }

    private let good = SkillsFixture.skill(name: "flight-add")

    // MARK: Golden path

    @Test("A well-formed bundle in its target produces nothing")
    func golden() throws {
        let fixture = try SkillsFixture(
            files: bundle(["flight-add/SKILL.md": good]), targets: [.init(name: "App", resources: ["Skills.skillsbundle"])])
        defer { fixture.remove() }
        #expect(SkillsAudit.analyze(root: fixture.root).isEmpty)
    }

    // MARK: Folder rules

    @Test("A skill folder name outside [a-z0-9-] is an error", arguments: ["Flight_Add", "flightAdd", "flight add", "flight.add"])
    func badFolderName(name: String) throws {
        let fixture = try SkillsFixture(files: bundle(["\(name)/SKILL.md": SkillsFixture.skill(name: "x")]))
        defer { fixture.remove() }
        let result = findings(fixture, rule: "skills.bad-folder-name")
        #expect(result.count == 1)
        #expect(result.first?.severity == .error)
        #expect(result.first?.message.contains(name) == true)
    }

    @Test("A folder with no SKILL.md is an error")
    func missingSkillMd() throws {
        let fixture = try SkillsFixture(files: bundle(["flight-add/notes.md": "x"]))
        defer { fixture.remove() }
        #expect(findings(fixture, rule: "skills.missing-skill-md").count == 1)
    }

    @Test("Anything beside SKILL.md is an error, but a .DS_Store is not")
    func extraFiles() throws {
        let fixture = try SkillsFixture(files: bundle([
            "flight-add/SKILL.md": good, "flight-add/README.md": "x", "flight-add/.DS_Store": "x",
            "flight-add/refs/a.md": "x",
        ]))
        defer { fixture.remove() }
        let result = findings(fixture, rule: "skills.extra-files")
        #expect(result.count == 1)
        #expect(result.first?.message.contains("README.md") == true)
        #expect(result.first?.message.contains("refs") == true)
        #expect(result.first?.message.contains("DS_Store") == false)
    }

    @Test("A skill folder that is a symlink out of the bundle is not followed")
    func symlinkedFolder() throws {
        let fixture = try SkillsFixture(
            files: ["Outside/flight-add/SKILL.md": good], directories: ["Skills.skillsbundle"])
        defer { fixture.remove() }
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("Skills.skillsbundle/flight-add"),
            withDestinationURL: fixture.root.appendingPathComponent("Outside/flight-add"))
        #expect(findings(fixture, rule: "skills.missing-skill-md").count == 1,
                "read through the link it would look well-formed")
    }

    // MARK: Frontmatter

    @Test("A key other than name and description is an error")
    func unknownKey() throws {
        let fixture = try SkillsFixture(files: bundle(["flight-add/SKILL.md": SkillsFixture.skill(name: "flight-add", extra: "version: 2\n")]))
        defer { fixture.remove() }
        let result = findings(fixture, rule: "skills.frontmatter-fields")
        #expect(result.count == 1)
        #expect(result.first?.message.contains("version") == true)
    }

    @Test("A missing name or description is an error each")
    func missingFields() throws {
        let noName = "---\ndescription: Adds a flight\n---\nbody\n"
        let noDescription = "---\nname: flight-add\n---\nbody\n"
        let fixture = try SkillsFixture(files: bundle(["a/SKILL.md": noName, "b/SKILL.md": noDescription]))
        defer { fixture.remove() }
        let messages = findings(fixture, rule: "skills.frontmatter-fields").map(\.message)
        #expect(messages.count == 2)
        #expect(messages.contains { $0.contains("name") })
        #expect(messages.contains { $0.contains("description") })
    }

    @Test("A SKILL.md with no frontmatter is an error")
    func noFrontmatter() throws {
        let fixture = try SkillsFixture(files: bundle(["flight-add/SKILL.md": "Just prose, no header.\n"]))
        defer { fixture.remove() }
        #expect(findings(fixture, rule: "skills.frontmatter-fields").count == 1)
    }

    // MARK: Body

    @Test("A body over 10,000 characters is an error; exactly 10,000 is not")
    func bodyLength() throws {
        let over = SkillsFixture.skill(name: "long", body: String(repeating: "a", count: 10_001))
        let exact = SkillsFixture.skill(name: "exact", body: String(repeating: "a", count: 10_000))
        let fixture = try SkillsFixture(files: bundle(["long/SKILL.md": over, "exact/SKILL.md": exact]))
        defer { fixture.remove() }
        let result = findings(fixture, rule: "skills.body-too-long")
        #expect(result.count == 1)
        #expect(result.first?.filePath?.hasSuffix("long/SKILL.md") == true)
    }

    @Test("A body naming an intent or entity type is a note")
    func namesType() throws {
        let body = "Call AddToCartIntent, then read the BookEntity it returns."
        let fixture = try SkillsFixture(files: bundle(["cart/SKILL.md": SkillsFixture.skill(name: "cart", body: body)]))
        defer { fixture.remove() }
        let result = findings(fixture, rule: "skills.names-type")
        #expect(result.count == 1)
        #expect(result.first?.severity == .note)
        #expect(result.first?.message.contains("AddToCartIntent") == true)
    }

    @Test("A body that describes the action in prose is not flagged")
    func prose() throws {
        let fixture = try SkillsFixture(files: bundle(["cart/SKILL.md": SkillsFixture.skill(name: "cart", body: "Search for the item, then add it to the cart.")]))
        defer { fixture.remove() }
        #expect(findings(fixture, rule: "skills.names-type").isEmpty)
    }

    // MARK: Project rules

    @Test("The same skill name in two bundles is an error on the second")
    func duplicateName() throws {
        let fixture = try SkillsFixture(files:
            bundle(["a/SKILL.md": good], name: "App.skillsbundle")
            .merging(bundle(["b/SKILL.md": good], name: "Widget.skillsbundle")) { a, _ in a })
        defer { fixture.remove() }
        let result = findings(fixture, rule: "skills.duplicate-name")
        #expect(result.count == 1)
        #expect(result.first?.message.contains("flight-add") == true)
    }

    @Test("A bundle no target copies is an error")
    func notInTarget() throws {
        let fixture = try SkillsFixture(
            files: bundle(["flight-add/SKILL.md": good]), targets: [.init(name: "App", resources: [])])
        defer { fixture.remove() }
        let result = findings(fixture, rule: "skills.bundle-not-in-target")
        #expect(result.count == 1)
        #expect(result.first?.severity == .error)
    }

    @Test("With no Xcode project there is no membership to judge")
    func noProject() throws {
        let fixture = try SkillsFixture(files: bundle(["flight-add/SKILL.md": good]))
        defer { fixture.remove() }
        #expect(findings(fixture, rule: "skills.bundle-not-in-target").isEmpty)
    }

    @Test("A bundle inside a synchronized folder is in the target, unless excluded from Resources")
    func synchronizedFolder() throws {
        let files = bundle(["flight-add/SKILL.md": good], name: "App/Skills.skillsbundle")
        let included = try SkillsFixture(files: files, targets: [.init(name: "App", synchronizedFolder: "App")])
        defer { included.remove() }
        #expect(findings(included, rule: "skills.bundle-not-in-target").isEmpty)

        let excluded = try SkillsFixture(
            files: files, targets: [.init(name: "App", synchronizedFolder: "App", exceptions: ["Skills.skillsbundle"])])
        defer { excluded.remove() }
        #expect(findings(excluded, rule: "skills.bundle-not-in-target").count == 1)
    }

    @Test("Two bundles in one target is an error naming the target")
    func multipleBundles() throws {
        let fixture = try SkillsFixture(
            files: bundle(["a/SKILL.md": good], name: "One.skillsbundle")
                .merging(bundle(["b/SKILL.md": SkillsFixture.skill(name: "other")], name: "Two.skillsbundle")) { a, _ in a },
            targets: [.init(name: "App", resources: ["One.skillsbundle", "Two.skillsbundle"])])
        defer { fixture.remove() }
        let result = findings(fixture, rule: "skills.multiple-bundles")
        #expect(result.count == 1)
        #expect(result.first?.message.contains("'App'") == true)
    }
}

@Suite("AppSkillsAuditor — checker")
struct AppSkillsCheckerTests {

    @Test("Identity")
    func identity() {
        let checker = AppSkillsAuditor()
        #expect(checker.id == "app-skills")
        #expect(checker.executesProjectCode == false)
    }

    @Test("A project with no skills bundle is skipped, not passed")
    func skippedWithoutBundles() async throws {
        let fixture = try SkillsFixture(files: ["Sources/A.swift": "struct A {}"])
        defer { fixture.remove() }
        var configuration = Configuration()
        configuration.projectRoot = fixture.root
        let result = try await AppSkillsAuditor().check(configuration: configuration)
        #expect(result.status == .skipped)
    }

    @Test("An error finding fails the check")
    func failsOnError() async throws {
        let fixture = try SkillsFixture(files: ["Skills.skillsbundle/Bad_Name/SKILL.md": SkillsFixture.skill(name: "x")])
        defer { fixture.remove() }
        var configuration = Configuration()
        configuration.projectRoot = fixture.root
        let result = try await AppSkillsAuditor().check(configuration: configuration)
        #expect(result.status == .failed)
    }
}
