import Foundation

/// How strictly `security.weak-crypto` is held.
///
/// ## Why a weak hash is sometimes the only correct answer
///
/// MD5 and SHA-1 are broken, and the rule that says so is right about new work. It is not
/// right about **reading a file format somebody else wrote**. An ECMA-376 encrypted
/// spreadsheet from the Excel 2010 era derives its key with SHA-1, and names the algorithm
/// inside the file; a reader either computes SHA-1 or refuses to open the document. The
/// checker's standing advice — "use SHA-256 or stronger" — is not available, because the
/// choice was made years ago by whoever saved the file.
///
/// That left a project three bad options: silence the rule, exclude the checker, or drop the
/// feature. A project whose own rules forbid suppression had none at all. This adds the
/// fourth, and it is the mechanism such projects already use for `@unchecked Sendable`:
/// **state the reason in the source, on the line above, where a reviewer reads it.**
///
/// ## Why there is no `aggregate`
///
/// ``TrapPolicy`` has one because traps are pervasive in code nobody owns, and reporting
/// every `fatalError` in a `Collection` conformance is how a checker gets excluded wholesale.
/// Weak hashes are rare — rare enough that each one can be looked at. A weak hash counted
/// silently into a footnote is precisely the outcome the rule exists to prevent, so the
/// choice here is binary: report it, or say why it is correct.
public enum WeakCryptoPolicy: String, Sendable, Codable, CaseIterable, Equatable {

    /// Report every use. The behaviour before this policy existed, and still the default.
    case forbidden

    /// Report a use unless the line above carries a `// Justification:` comment.
    case justified

    /// The default policy, chosen so that adding this changes nothing for anyone.
    public static let `default` = WeakCryptoPolicy.forbidden
}

extension WeakCryptoPolicy: GraduatedPolicy {

    /// This family has no context relaxation, so the context it reads is empty.
    ///
    /// A trap's harm depends on *who the caller is* — an end user cannot act on a crash, a
    /// programmer with a stack trace can — which is a fact about the target, and why
    /// ``TrapPolicy`` relaxes by target type. A weak hash's harm depends on *what it is used
    /// for*: deriving a key for a legacy file is not the same act as protecting new data, and
    /// no property of the enclosing target distinguishes them. Only a written reason does.
    public typealias Context = Void

    /// The strength this policy is being held at.
    public var level: PolicyLevel {
        switch self {
        case .forbidden: return .forbidden
        case .justified: return .justified
        }
    }

    /// Never — see ``Context`` for why this family relaxes by reason rather than by place.
    ///
    /// - Parameter context: Unused.
    /// - Returns: `false`, always.
    public func alwaysReports(in context: Void) -> Bool { false }

    /// The noun an aggregate note would count, were there an aggregate level.
    public var aggregateNoun: String { "weak hash" }
}
