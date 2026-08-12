import Foundation

/// Which section of `README.md`'s checker reference a checker belongs under.
///
/// ## This is an editorial judgment, deliberately frozen into a type
///
/// The grouping is not derived from anything — `safety` could defensibly sit under Correctness,
/// and `accessibility` under Safety. It is a decision about what makes the reference readable,
/// and moving it into source freezes that decision where changing it is a code review.
///
/// The alternative was one flat table with the headings left as prose outside the generated
/// regions, which would have kept the judgment out of the type system entirely. It was rejected
/// because a 42-row flat table is worse to read than six grouped ones, and readability is the
/// only reason the table exists. Paying for it in a type is the smaller cost.
///
/// The order of `allCases` is the order the sections appear in the README, so a generated
/// table cannot silently reorder a reference somebody arranged on purpose.
public enum CheckerCategory: String, Sendable, Codable, CaseIterable, Equatable {

    /// Does the code do what it says: recursion, aliasing, concurrency, dead code, complexity.
    case correctness

    /// Does the code expose the user: unsafe unwraps, secrets, determinism, platform guidelines.
    case safetySecurity = "safety-security"

    /// Is the code livable: logging, test quality, consent, accessibility.
    case codeHygiene = "code-hygiene"

    /// Does the documentation hold: coverage, DocC build, compilable examples.
    case documentation

    /// Is the project shippable: build, test, docs-vs-code drift, dependencies, releases.
    case projectHealth = "project-health"

    /// Everything whose audience is narrower than the package: MCP, App Intents, Xcode, IJS.
    case specialty

    /// The `###` heading this category appears under in `README.md`.
    public var heading: String {
        switch self {
        case .correctness: "Correctness"
        case .safetySecurity: "Safety & Security"
        case .codeHygiene: "Code Hygiene"
        case .documentation: "Documentation"
        case .projectHealth: "Project Health"
        case .specialty: "Specialty"
        }
    }

    /// The category a README heading names, or `nil` when no category claims it.
    ///
    /// The inverse of ``heading``, and the thing that lets a generated region be matched to the
    /// section it belongs in rather than to its position in the file.
    ///
    /// - Parameter heading: The heading text, without the `###`.
    public init?(heading: String) {
        guard let match = Self.allCases.first(where: { $0.heading == heading }) else { return nil }
        self = match
    }
}
