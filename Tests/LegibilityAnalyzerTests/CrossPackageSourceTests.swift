import Foundation
import Testing
@testable import LegibilityAnalyzer

@Suite("Cross-package sources")
struct CrossPackageSourceTests {

    // MARK: - externalPackageDependencies

    private let manifest = """
    // swift-tools-version: 6.2
    // legibility:description: Core game logic and models for the Iconquer suite.
    import PackageDescription
    let package = Package(
        name: "IconquerApp",
        dependencies: [
            .package(url: "https://github.com/jpurnell/IconquerCore.git", from: "1.0.0"),
            .package(url: "https://github.com/jpurnell/IconquerGameKit", from: "1.0.0"),
            .package(path: "../IconquerClient"),
            .package(url: "https://github.com/apple/swift-syntax.git", from: "600.0.0"),
        ]
    )
    """

    @Test("extracts external package identities, stripping .git and paths")
    func externalDeps() {
        let deps = PackageGraphLoader.externalPackageDependencies(packageSource: manifest)
        #expect(deps.contains("IconquerCore"))       // .git stripped
        #expect(deps.contains("IconquerGameKit"))    // no .git
        #expect(deps.contains("IconquerClient"))     // from path:
        #expect(deps.contains("swift-syntax"))       // external OSS kept (dashboard filters later)
        #expect(deps == deps.sorted())               // deterministic
    }

    @Test("packageIdentity takes the last path component minus .git")
    func identity() {
        #expect(PackageGraphLoader.packageIdentity(from: "https://github.com/jpurnell/BusinessMath.git") == "BusinessMath")
        #expect(PackageGraphLoader.packageIdentity(from: "https://github.com/jpurnell/BusinessMath") == "BusinessMath")
        #expect(PackageGraphLoader.packageIdentity(from: "../Local/Foo/") == "Foo")
    }

    // MARK: - packageDescription (Package.swift comment)

    @Test("reads the non-actionable legibility:description comment")
    func packageDescriptionComment() {
        #expect(PackageGraphLoader.packageDescription(packageSource: manifest)
            == "Core game logic and models for the Iconquer suite.")
    }

    @Test("absent description comment yields nil")
    func noPackageDescription() {
        #expect(PackageGraphLoader.packageDescription(packageSource: "let package = Package(name: \"X\")") == nil)
    }

    // MARK: - MasterPlanReader

    private let masterPlan = """
    # Project Master Plan

    ## Project Overview

    ### Mission

    Provide a modular, AST-powered static analysis toolkit for Swift projects.

    ### Target Users

    Swift teams.

    ## Current Status

    ### What's Working

    - [x] SafetyAuditor — Code safety and OWASP security checks
    - [x] ComplexityAnalyzer — Cognitive complexity and Big-O estimation
    - [ ] FutureThing — Not built yet
    """

    @Test("parses module descriptions from checklist lines")
    func descriptions() {
        let d = MasterPlanReader.descriptions(markdown: masterPlan)
        #expect(d["SafetyAuditor"] == "Code safety and OWASP security checks")
        #expect(d["ComplexityAnalyzer"] == "Cognitive complexity and Big-O estimation")
        #expect(d["FutureThing"] == "Not built yet")   // unchecked still described
    }

    @Test("parses the Mission as the package summary")
    func mission() {
        #expect(MasterPlanReader.mission(markdown: masterPlan)
            == "Provide a modular, AST-powered static analysis toolkit for Swift projects.")
    }

    @Test("missing Mission section yields nil")
    func noMission() {
        #expect(MasterPlanReader.mission(markdown: "# Doc\n\nNo mission here.") == nil)
    }
}
