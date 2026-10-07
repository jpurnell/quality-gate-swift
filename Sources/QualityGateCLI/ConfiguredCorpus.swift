import ArgumentParser
import Foundation
import QualityGateCore

/// The corpus a subcommand should use: its `--corpus-path` flag, else the configuration.
///
/// One function, so that the six subcommands and the skip recorder cannot each read
/// `consistency.corpusPath` and act on it as written. A flag is taken as given — the shell
/// that passed it has already done any expanding. A configured value goes through
/// `CorpusLocation`, and one the gate refuses ends the command with the reason rather
/// than degrading to "no corpus configured", which would send the reader to add a key that
/// is already there.
enum ConfiguredCorpus {

    /// Resolves the effective corpus path.
    ///
    /// - Parameters:
    ///   - flag: The subcommand's `--corpus-path`, if given.
    ///   - configuration: The loaded configuration.
    ///   - tag: The subcommand's output prefix, as in `[ijs]`.
    /// - Returns: The path to use, or `nil` when neither source names one.
    /// - Throws: `ExitCode(1)` when the configured value is refused.
    static func path(flag: String?, configuration: Configuration, tag: String) throws -> String? {
        if let flag { return flag }
        switch configuration.corpusLocation() {
        case .unconfigured:
            return nil
        case .usable(let path):
            return path
        case .rejected(let problem):
            FileHandle.standardError.write(Data("[\(tag)] Error: \(problem.message)\n".utf8))
            throw ExitCode(1)
        }
    }
}
