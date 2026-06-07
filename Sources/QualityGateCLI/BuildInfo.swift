import ArgumentParser

struct BuildInfo: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "build-info",
        abstract: "Show the build stamp (git commit, build date) of this binary."
    )

    @Flag(name: .long, help: "Print only the full commit hash")
    var commit: Bool = false

    @Flag(name: .long, help: "Print only the build date")
    var date: Bool = false

    func run() throws {
        if commit {
            print(BuildStamp.gitCommit)
        } else if date {
            print(BuildStamp.buildDate)
        } else {
            print("commit: \(BuildStamp.gitCommit)")
            print("built:  \(BuildStamp.buildDate)")
        }
    }
}
