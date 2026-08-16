import ArgumentParser
import QualityGateCore

/// Lets `--profile` parse a ``CheckerProfile`` directly.
///
/// The conformance lives here rather than on the type so `QualityGateCore` does not take a
/// dependency on ArgumentParser for the sake of one initializer.
///
/// `ExpressibleByArgument`'s failable init is what makes an unknown profile name an
/// ArgumentParser error listing the valid values, rather than a silent empty selection. That
/// distinction is not hypothetical here: `enabledCheckers: [all]` once matched no checker id,
/// ran nothing, and still printed PASSED.
extension CheckerProfile: ExpressibleByArgument {

    /// All profile names, shown in `--help` and in the error for an unknown value.
    public static var allValueStrings: [String] { allCases.map(\.rawValue) }
}
