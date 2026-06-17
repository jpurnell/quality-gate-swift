import Testing
@testable import SubmoduleAuditor

@Suite("SubmoduleAuditor: Identity")
struct SubmoduleAuditorIdentityTests {
    @Test("SubmoduleAuditor has correct id and name")
    func checkerIdentity() {
        let auditor = SubmoduleAuditor()
        #expect(auditor.id == "submodule-audit")
        #expect(auditor.name == "Submodule Auditor")
    }
}

@Suite("SubmoduleAuditor: .gitmodules parsing")
struct SubmoduleAuditorParsingTests {

    @Test("Parses submodule names from .gitmodules content")
    func parsesNames() {
        let content = """
        [submodule "development-guidelines"]
        \tpath = development-guidelines
        \turl = https://github.com/jpurnell/development-guidelines
        [submodule "shared-fixtures"]
        \tpath = shared-fixtures
        \turl = https://github.com/jpurnell/shared-fixtures
        """
        let auditor = SubmoduleAuditor()
        let names = auditor.parseSubmoduleNames(from: content)
        #expect(names == ["development-guidelines", "shared-fixtures"])
    }

    @Test("Parses submodule URLs from .gitmodules content")
    func parsesURLs() {
        let content = """
        [submodule "dev-guidelines"]
        \tpath = dev-guidelines
        \turl = https://github.com/jpurnell/development-guidelines
        """
        let auditor = SubmoduleAuditor()
        let urls = auditor.parseSubmoduleURLs(from: content)
        #expect(urls == ["https://github.com/jpurnell/development-guidelines"])
    }

    @Test("Returns empty for content with no submodules")
    func emptyContent() {
        let auditor = SubmoduleAuditor()
        #expect(auditor.parseSubmoduleNames(from: "").isEmpty)
        #expect(auditor.parseSubmoduleURLs(from: "").isEmpty)
    }
}
