import Foundation

/// The gate's one answer to "does this name denote something sensitive?"
///
/// Five proposals and two shipped rules each needed this question answered, and before this type
/// existed the gate answered it twice, differently: `security.hardcoded-secret` lower-cased the
/// name and tested `contains(pattern)` — so `tokenizer` and `secretary` were credentials — while
/// `keychain-secrets` tokenised it into words. This is the tokenising answer, lifted to
/// `QualityGateCore` and widened to the union of every vocabulary the proposals define
/// (`ideas/TheGateIsNotYetAggressive.md` §2.1, last row; §2.2 item 5).
///
/// ## Words, not substrings
///
/// An identifier in any spelling — `camelCase`, `snake_case`, `SCREAMING_CASE`, a dotted or
/// hyphenated key, the text of a string-literal key such as `"api_key"` — is split by ``words(_:)``
/// into lower-cased whole words, with acronym boundaries honoured (`APIKey` → `api`, `key`). A
/// vocabulary ``Term`` matches a *contiguous run* of those words whose concatenation is the term's
/// spelling, or that run with one trailing `s` (a plural). Letters and digits split, so `token1`
/// is `token` `1`. So:
///
/// - `apiKey`, `api_key`, `API_KEY`, `x-api-key` and the single word `apikey` all match `apikey`;
/// - `apiKeyboard` does not — `api` + `keyboard` is not a run that spells `apikey`, although the
///   concatenation `apikeyboard` *contains* it;
/// - `tokenizer`, `secretary`, `keyboard`, `passwordless`, `basalt` match nothing. A word that
///   contains a term is a different word. `passwordless` names the *absence* of a password, and
///   is deliberately not one.
/// - A run-together lower-case identifier matches only if it is itself a term (`accesstoken`
///   does; `myapikey` does not). That is the price of refusing substrings, and it is pinned.
///
/// ## One matcher, rules choose their words
///
/// The shipped rules moved onto this matcher **without** moving onto the union vocabulary:
/// `keychain-secrets` and `security.hardcoded-secret` call
/// ``classify(_:restrictedTo:additionalTerms:)`` with their own ``Origin`` and so see exactly
/// the words they shipped with. Measured over the portfolio, giving `hardcoded-secret` the union
/// added nineteen findings — OAuth grant-type and header-name constants (`authorizationCode`,
/// `bearer`, `sessionID`), a regex named `bearerPattern`, and test-fixture passphrases — and
/// removed none. Widening a rule's words is a decision with its own measurement; a refactor is
/// not the place to make it. New rules take the whole vocabulary by default.
///
/// ## Two questions, both answered
///
/// The shipped rules ask *does the name mention a secret anywhere* —
/// ``Classification/namesSecret``. `tokenCount` does. The logging rule
/// (`PublicIsAClaimAboutTheValue.md` §4.1) asks *is the secret the head of the name* —
/// ``Classification/headCategory`` — because the head of an English compound is its last word:
/// `accessToken` is a token, `tokenCount` is a number, and a plural head (`inputTokens`) is not
/// counted, because in this portfolio it is usually a count of LLM tokens. Trailing value-carrier words (`value`,
/// `string`, `data`, `bytes`, `header`, `text`, `raw`) are looked through first, so
/// `authorizationHeaderValue` is an authorization. The context predicate
/// (`ASeedIsNotASecret.md` §3.1) asks a third: a match anywhere, unless the name ends in a
/// ``Classification/descriptor`` such as `name`, `count` or `expiry`.
///
/// ## Vocabulary and origins
///
/// Every term records where it came from in ``Term/origins``; the table is the same data.
///
/// | term | category | strength | origins |
/// |---|---|---|---|
/// | `token` | credential | strong | hardcoded-secret, keychain-secrets, PublicIsAClaimAboutTheValue, ASeedIsNotASecret |
/// | `secret` | credential | strong | hardcoded-secret, keychain-secrets, PublicIsAClaimAboutTheValue, ASeedIsNotASecret |
/// | `credential` | credential | strong | hardcoded-secret, keychain-secrets, PublicIsAClaimAboutTheValue |
/// | `bearer` | credential | strong | keychain-secrets, PublicIsAClaimAboutTheValue |
/// | `apikey` | credential | strong | hardcoded-secret, keychain-secrets, PublicIsAClaimAboutTheValue, ASeedIsNotASecret |
/// | `authtoken`, `accesstoken`, `refreshtoken`, `clientsecret` | credential | strong | keychain-secrets, PublicIsAClaimAboutTheValue; hardcoded-secret (its substring test matched them run together) |
/// | `authorization`, `cookie`, `setcookie`, `jwt`, `sessionid` | credential | strong | PublicIsAClaimAboutTheValue |
/// | `otp` | credential | strong | PublicIsAClaimAboutTheValue, ASeedIsNotASecret |
/// | `authcode` | credential | strong | ASeedIsNotASecret |
/// | `password` | password | strong | hardcoded-secret, keychain-secrets, PublicIsAClaimAboutTheValue, ASeedIsNotASecret, ACipherIsItsArguments |
/// | `passwd` | password | strong | keychain-secrets, PublicIsAClaimAboutTheValue, ACipherIsItsArguments |
/// | `passphrase` | password | strong | PublicIsAClaimAboutTheValue, ASeedIsNotASecret, ACipherIsItsArguments |
/// | `passcode` | password | strong | hig.secure-field |
/// | `pin` | password | **weak** | ACipherIsItsArguments (weak-kdf) |
/// | `privatekey` | keyMaterial | strong | hardcoded-secret, keychain-secrets, PublicIsAClaimAboutTheValue, ASeedIsNotASecret |
/// | `sessionkey` | keyMaterial | strong | keychain-secrets, PublicIsAClaimAboutTheValue, ASeedIsNotASecret |
/// | `secretkey`, `signingkey`, `encryptionkey` | keyMaterial | strong | ASeedIsNotASecret |
/// | `key` | keyMaterial | **weak** | ASeedIsNotASecret |
/// | `nonce`, `salt`, `challenge`, `verifier`, `csrf`, `session` | securityParameter | strong | ASeedIsNotASecret |
/// | `iv`, `initializationvector` | securityParameter | strong | ACipherIsItsArguments (static-iv) |
/// | `state` | securityParameter | **weak** | ASeedIsNotASecret |
/// | `email`, `ssn`, `socialsecurity`, `dob`, `dateofbirth`, `patientname`, `mrn`, `medicalrecord`, `phonenumber`, `homeaddress`, `diagnosis`, `prescription` | personalData | strong | PIITaintGate (via PublicIsAClaimAboutTheValue §4.1) |
///
/// Deliberately **not** terms: `nonce` and `signature` as *credentials* (tried and dropped by
/// `PublicIsAClaimAboutTheValue` §6 as noise — `nonce` is here only as a security parameter);
/// `pwd` (also "print working directory"); `client_id` (not a secret —
/// `TheSecretsAreInFilesNobodyWrote` §2). `secret-in-query`'s list of query *names* is an exact
/// list owned by that rule, not vocabulary.
///
/// A **weak** term never classifies a name on its own: `key` is every dictionary key, `state` is
/// every reducer, `pin` is every map pin. It counts only when a caller asks for it
/// (``Classification/contains(_:includingWeak:)``) or, in ``SecurityContext``, inside a
/// security-named scope.
///
/// ## Usage
///
/// ```swift
/// // keychain-secrets: a secret word anywhere in the name, from the words it shipped with.
/// let extras = [SensitiveName.customTerm("license_key")]
/// let flagged = SensitiveName.classify(
///     "cachedLicenseKey", restrictedTo: .keychainSecretsRule, additionalTerms: extras).namesSecret
///
/// // credential-in-log: the head of the terminal name of a member path.
/// let path = ["user", "credentials", "refreshToken", "value"]
/// let terminal = SensitiveName.terminalName(ofMemberPath: path) ?? ""
/// let isCredential = SensitiveName.classify(terminal).headCategory?.isSecret ?? false
///
/// // weak-kdf: a password-class word, the weak `pin` included.
/// let isPassword = SensitiveName.classify("userPin").contains(.password, includingWeak: true)
/// ```
public enum SensitiveName {

    /// What kind of sensitive thing a term names.
    public enum Category: String, Sendable, CaseIterable, Codable, Hashable {
        /// Possession authorises: a bearer token, API key, cookie, session id.
        case credential
        /// A human-chosen secret, attackable by dictionary: password, passphrase, passcode, PIN.
        case password
        /// Cryptographic key material.
        case keyMaterial
        /// A value that must be unpredictable but need not be secret: nonce, salt, IV, challenge.
        case securityParameter
        /// Personal data (`PIITaintGate` source 3). Never a secret and never a security context.
        case personalData

        /// True for the categories whose disclosure is a credential leak — the shipped rules' test.
        public var isSecret: Bool {
            switch self {
            case .credential, .password, .keyMaterial: true
            case .securityParameter, .personalData: false
            }
        }

        /// True for the categories that put a value in a security context (`ASeedIsNotASecret` §3.1).
        public var isSecurityRelevant: Bool {
            self != .personalData
        }
    }

    /// Whether a term is sufficient on its own.
    public enum Strength: String, Sendable, Codable, Hashable {
        /// Classifies a name by itself.
        case strong
        /// Counts only when a caller asks, or inside a security-named scope.
        case weak
    }

    /// One vocabulary entry.
    public struct Term: Sendable, Hashable {
        /// Lower-case alphanumerics: the concatenation of the words it matches (`apikey`).
        public let spelling: String
        /// What the term names.
        public let category: Category
        /// Whether it is sufficient alone.
        public let strength: Strength
        /// The rules and proposals that asked for this term.
        public let origins: [Origin]

        /// Creates a term; `spelling` is normalised.
        public init(spelling: String, category: Category, strength: Strength = .strong, origins: [Origin]) {
            self.spelling = SensitiveName.normalize(spelling)
            self.category = category
            self.strength = strength
            self.origins = origins
        }
    }

    /// One place a term matched.
    public struct Match: Sendable, Equatable {
        /// The term that matched.
        public let term: Term
        /// The words it covered, as indices into ``Classification/words``.
        public let wordRange: Range<Int>
        /// True when the run spelled the term with one trailing `s` (`tokens`, `apiKeys`).
        public let isPlural: Bool
    }

    /// Everything the matcher knows about one identifier.
    public struct Classification: Sendable, Equatable {
        /// The identifier as given.
        public let identifier: String
        /// Its words, lower-cased.
        public let words: [String]
        /// Every match, strong and weak, ordered by end word then length.
        public let matches: [Match]
        /// The category of a strong match that is the head of the name, after looking through
        /// trailing value-carrier words. `nil` when the name is *about* a sensitive thing
        /// (`tokenCount`) or names none.
        public let headCategory: Category?
        /// The descriptor that disqualifies the name in ``SecurityContext``: a trailing word such
        /// as `name`, `count`, `expiry`, or a leading quantifier such as `max`, `num`.
        public let descriptor: String?

        /// The categories of every strong match, anywhere in the name.
        public var categories: Set<Category> {
            Set(matches.filter { $0.term.strength == .strong }.map(\.term.category))
        }

        /// The categories of every weak match.
        public var weakCategories: Set<Category> {
            Set(matches.filter { $0.term.strength == .weak }.map(\.term.category))
        }

        /// True when a strong secret-category term appears anywhere in the name — the test
        /// `security.hardcoded-secret` and `keychain-secrets` apply.
        public var namesSecret: Bool {
            matches.contains { $0.term.strength == .strong && $0.term.category.isSecret }
        }

        /// True when a term of `category` matched; weak terms count only when asked.
        public func contains(_ category: Category, includingWeak: Bool = false) -> Bool {
            matches.contains { match in
                match.term.category == category && (includingWeak || match.term.strength == .strong)
            }
        }
    }

    // MARK: - Vocabulary

    /// Where a term came from: a shipped rule's own list, or a proposal that defined one.
    public enum Origin: String, Sendable, Hashable, CaseIterable {
        /// `SecurityAuditorConfig.secretPatterns`, the default list of `security.hardcoded-secret`.
        case hardcodedSecretRule = "hardcoded-secret"
        /// `KeychainSecretsChecker`'s single words and compounds.
        case keychainSecretsRule = "keychain-secrets"
        /// `HIGAuditor`'s `hig.secure-field` label words (not migrated; a UI-label test).
        case secureFieldRule = "hig.secure-field"
        /// `plans/proposals/PublicIsAClaimAboutTheValue.md` §4.1.
        case publicIsAClaim = "PublicIsAClaimAboutTheValue"
        /// `plans/proposals/ASeedIsNotASecret.md` §3.1.
        case aSeed = "ASeedIsNotASecret"
        /// `plans/proposals/ACipherIsItsArguments.md` §3.3, §3.5.
        case aCipher = "ACipherIsItsArguments"
        /// `plans/proposals/PIITaintGate.md` source 3.
        case piiTaintGate = "PIITaintGate"
        /// A project's `.quality-gate.yml` (`secretPatterns`, `extraPatterns`).
        case configuration

        /// Whether a classification restricted to this origin matches the plural of `term`.
        ///
        /// `security.hardcoded-secret` tested `contains`, so every plural matched it and still
        /// does. `keychain-secrets` matched its single words whole — never `tokens` — but found
        /// its compounds by substring, so `apiKeys` and `access_tokens` matched. Both are kept:
        /// measured over the portfolio, plural single words would have added `maxTokens`,
        /// `inputTokens` and `totalTokens`, which are counts.
        public func matchesPlural(of term: Term) -> Bool {
            switch self {
            case .keychainSecretsRule: SensitiveName.keychainCompounds.contains(term.spelling)
            default: true
            }
        }
    }

    /// The built-in vocabulary: the union of every list the gate shipped or a proposal defined.
    public static let vocabulary: [Term] = [
        // credential
        Term(spelling: "token", category: .credential, origins: [.hardcodedSecretRule, .keychainSecretsRule, .publicIsAClaim, .aSeed]),
        Term(spelling: "secret", category: .credential, origins: [.hardcodedSecretRule, .keychainSecretsRule, .publicIsAClaim, .aSeed]),
        Term(spelling: "credential", category: .credential, origins: [.hardcodedSecretRule, .keychainSecretsRule, .publicIsAClaim]),
        Term(spelling: "bearer", category: .credential, origins: [.keychainSecretsRule, .publicIsAClaim]),
        Term(spelling: "apikey", category: .credential, origins: [.hardcodedSecretRule, .keychainSecretsRule, .publicIsAClaim, .aSeed]),
        Term(spelling: "authtoken", category: .credential, origins: [.hardcodedSecretRule, .keychainSecretsRule, .publicIsAClaim]),
        Term(spelling: "accesstoken", category: .credential, origins: [.hardcodedSecretRule, .keychainSecretsRule, .publicIsAClaim]),
        Term(spelling: "refreshtoken", category: .credential, origins: [.hardcodedSecretRule, .keychainSecretsRule, .publicIsAClaim]),
        Term(spelling: "clientsecret", category: .credential, origins: [.hardcodedSecretRule, .keychainSecretsRule, .publicIsAClaim]),
        Term(spelling: "authorization", category: .credential, origins: [.publicIsAClaim]),
        Term(spelling: "cookie", category: .credential, origins: [.publicIsAClaim]),
        Term(spelling: "setcookie", category: .credential, origins: [.publicIsAClaim]),
        Term(spelling: "jwt", category: .credential, origins: [.publicIsAClaim]),
        Term(spelling: "otp", category: .credential, origins: [.publicIsAClaim, .aSeed]),
        Term(spelling: "sessionid", category: .credential, origins: [.publicIsAClaim]),
        Term(spelling: "authcode", category: .credential, origins: [.aSeed]),
        // password
        Term(spelling: "password", category: .password, origins: [.hardcodedSecretRule, .keychainSecretsRule, .publicIsAClaim, .aSeed, .aCipher]),
        Term(spelling: "passwd", category: .password, origins: [.keychainSecretsRule, .publicIsAClaim, .aCipher]),
        Term(spelling: "passphrase", category: .password, origins: [.publicIsAClaim, .aSeed, .aCipher]),
        Term(spelling: "passcode", category: .password, origins: [.secureFieldRule]),
        Term(spelling: "pin", category: .password, strength: .weak, origins: [.aCipher]),
        // key material
        Term(spelling: "privatekey", category: .keyMaterial, origins: [.hardcodedSecretRule, .keychainSecretsRule, .publicIsAClaim, .aSeed]),
        Term(spelling: "sessionkey", category: .keyMaterial, origins: [.keychainSecretsRule, .publicIsAClaim, .aSeed]),
        Term(spelling: "secretkey", category: .keyMaterial, origins: [.aSeed]),
        Term(spelling: "signingkey", category: .keyMaterial, origins: [.aSeed]),
        Term(spelling: "encryptionkey", category: .keyMaterial, origins: [.aSeed]),
        Term(spelling: "key", category: .keyMaterial, strength: .weak, origins: [.aSeed]),
        // security parameters
        Term(spelling: "nonce", category: .securityParameter, origins: [.aSeed]),
        Term(spelling: "salt", category: .securityParameter, origins: [.aSeed]),
        Term(spelling: "challenge", category: .securityParameter, origins: [.aSeed]),
        Term(spelling: "verifier", category: .securityParameter, origins: [.aSeed]),
        Term(spelling: "csrf", category: .securityParameter, origins: [.aSeed]),
        Term(spelling: "session", category: .securityParameter, origins: [.aSeed]),
        Term(spelling: "iv", category: .securityParameter, origins: [.aCipher]),
        Term(spelling: "initializationvector", category: .securityParameter, origins: [.aCipher]),
        Term(spelling: "state", category: .securityParameter, strength: .weak, origins: [.aSeed]),
        // personal data
        Term(spelling: "email", category: .personalData, origins: [.piiTaintGate, .publicIsAClaim]),
        Term(spelling: "ssn", category: .personalData, origins: [.piiTaintGate, .publicIsAClaim]),
        Term(spelling: "socialsecurity", category: .personalData, origins: [.piiTaintGate]),
        Term(spelling: "dob", category: .personalData, origins: [.piiTaintGate]),
        Term(spelling: "dateofbirth", category: .personalData, origins: [.piiTaintGate]),
        Term(spelling: "patientname", category: .personalData, origins: [.piiTaintGate]),
        Term(spelling: "mrn", category: .personalData, origins: [.piiTaintGate]),
        Term(spelling: "medicalrecord", category: .personalData, origins: [.piiTaintGate]),
        Term(spelling: "phonenumber", category: .personalData, origins: [.piiTaintGate]),
        Term(spelling: "homeaddress", category: .personalData, origins: [.piiTaintGate]),
        Term(spelling: "diagnosis", category: .personalData, origins: [.piiTaintGate]),
        Term(spelling: "prescription", category: .personalData, origins: [.piiTaintGate]),
    ]

    /// Trailing words that make a name *describe* a sensitive value rather than hold one
    /// (`ASeedIsNotASecret` §3.1).
    public static let descriptorSuffixes: Set<String> = [
        "name", "label", "count", "length", "size", "type", "kind", "path", "url", "prefix",
        "title", "date", "expiry", "lifetime", "ttl", "index",
    ]

    /// Leading quantifiers that make a name a number about sensitive things: `maxTokens` is a
    /// budget, not a token (`TheSecretsAreInFilesNobodyWrote` §2 measured it as noise).
    public static let quantifierPrefixes: Set<String> = ["max", "min", "num", "total"]

    /// Trailing words that carry the value they follow — `tokenString`, `passwordData`,
    /// `authorizationHeader` — and are looked through when finding the head.
    public static let carrierSuffixes: Set<String> = ["value", "string", "data", "bytes", "header", "text", "raw"]

    /// Member-path components that are the value of the component before them
    /// (`PublicIsAClaimAboutTheValue` §4.1).
    public static let transparentMembers: Set<String> = ["value", "rawValue", "string", "description", "utf8"]

    /// The longest run of words any built-in term spans (`date` `of` `birth`), plus slack for
    /// configured terms.
    private static let maximumRunLength = 4

    private static let builtInIndex: [String: Term] = {
        var index: [String: Term] = [:]
        for term in vocabulary { index[term.spelling] = term }
        return index
    }()

    /// `keychain-secrets`' compound list, which it matched by substring (and so in the plural).
    static let keychainCompounds: Set<String> = [
        "apikey", "authtoken", "accesstoken", "refreshtoken", "privatekey", "clientsecret", "sessionkey",
    ]

    /// One index per origin, for a rule that keeps the words it shipped with.
    private static let originIndexes: [Origin: [String: Term]] = {
        var indexes: [Origin: [String: Term]] = [:]
        for term in vocabulary {
            for origin in term.origins { indexes[origin, default: [:]][term.spelling] = term }
        }
        return indexes
    }()

    // MARK: - API

    /// A configured term: normalised, strong, origin `configuration`.
    public static func customTerm(_ raw: String, category: Category = .credential) -> Term {
        Term(spelling: raw, category: category, strength: .strong, origins: [.configuration])
    }

    /// Lower-cased alphanumerics only.
    public static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Splits an identifier or key into lower-cased words on non-alphanumerics and on case
    /// boundaries, including acronym→word boundaries (`APIKey` → `api`, `key`).
    public static func words(_ identifier: String) -> [String] {
        var words: [String] = []
        var current = ""
        let characters = Array(identifier)

        for index in characters.indices {
            let character = characters[index]
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current.lowercased()); current = "" }
                continue
            }
            if let last = current.last {
                let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
                // Letters and digits are separate words: `token1` is `token` `1`, `sha256` is
                // `sha` `256`. The substring test this replaced matched `token1`; without the
                // split, whole-word matching would have stopped.
                let digitBoundary = last.isNumber != character.isNumber
                let camelBoundary = character.isUppercase && last.isLowercase
                let acronymBoundary = character.isUppercase && last.isUppercase && (next?.isLowercase ?? false)
                if digitBoundary || camelBoundary || acronymBoundary {
                    words.append(current.lowercased())
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }

    /// The name a member path denotes: its last component, or the one before when the last is a
    /// value-carrier member (`refreshToken.value`, `token.rawValue`, `password.utf8`).
    public static func terminalName(ofMemberPath path: [String]) -> String? {
        var remaining = path[...]
        while remaining.count > 1, let last = remaining.last, transparentMembers.contains(last) {
            remaining = remaining.dropLast()
        }
        return remaining.last
    }

    /// The built-in terms that `origin` asked for.
    public static func terms(from origin: Origin) -> [Term] {
        vocabulary.filter { $0.origins.contains(origin) }
    }

    /// Classifies `identifier` against the built-in vocabulary plus `additionalTerms`.
    ///
    /// - Parameters:
    ///   - identifier: An identifier, member name or key text, in any spelling.
    ///   - origin: When given, only the built-in terms that origin asked for are used. This is
    ///     how a shipped rule moves onto the shared *matcher* without moving onto the wider
    ///     *vocabulary*: widening a rule's word list is a decision with its own measurement,
    ///     not a side effect of a refactor.
    ///   - additionalTerms: Configured terms, added to whichever vocabulary applies.
    public static func classify(
        _ identifier: String,
        restrictedTo origin: Origin? = nil,
        additionalTerms: [Term] = []
    ) -> Classification {
        let words = words(identifier)
        var index = origin.map { originIndexes[$0] ?? [:] } ?? builtInIndex
        for term in additionalTerms where !term.spelling.isEmpty && index[term.spelling] == nil {
            index[term.spelling] = term
        }

        var matches: [Match] = []
        for end in words.indices {
            var run = ""
            var start = end
            // Grow the run leftward from `end`, so matches come out ordered by end word.
            while start >= 0, end - start < maximumRunLength {
                run = words[start] + run
                if let term = index[run] {
                    matches.append(Match(term: term, wordRange: start..<(end + 1), isPlural: false))
                } else if let term = pluralLookup(run, in: index), origin?.matchesPlural(of: term) ?? true {
                    matches.append(Match(term: term, wordRange: start..<(end + 1), isPlural: true))
                }
                start -= 1
            }
        }

        return Classification(
            identifier: identifier,
            words: words,
            matches: matches,
            headCategory: headCategory(words: words, matches: matches),
            descriptor: descriptor(words: words))
    }

    // MARK: - Internals

    /// The term spelled by `run` less one plural `s`.
    private static func pluralLookup(_ run: String, in index: [String: Term]) -> Term? {
        guard run.count > 1, run.hasSuffix("s") else { return nil }
        return index[String(run.dropLast())]
    }

    private static func headCategory(words: [String], matches: [Match]) -> Category? {
        var headEnd = words.count
        while headEnd > 1, carrierSuffixes.contains(words[headEnd - 1]) {
            headEnd -= 1
        }
        // Longest strong run ending at the head wins: `sessionId` is a session id, not a session.
        // A plural head does not count: `inputTokens` is a count of LLM tokens far more often
        // than a collection of credentials (`TheSecretsAreInFilesNobodyWrote` §2, `maxTokens`).
        let candidates = matches.filter {
            $0.term.strength == .strong && !$0.isPlural && $0.wordRange.upperBound == headEnd
        }
        let longest = candidates.max { $0.wordRange.count < $1.wordRange.count }
        return longest?.term.category
    }

    private static func descriptor(words: [String]) -> String? {
        if words.count > 1, let last = words.last, descriptorSuffixes.contains(last) {
            return last
        }
        if words.count > 1, let first = words.first, quantifierPrefixes.contains(first) {
            return first
        }
        return nil
    }
}
