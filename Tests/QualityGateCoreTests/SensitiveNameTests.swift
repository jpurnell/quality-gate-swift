import Foundation
import Testing
@testable import QualityGateCore

/// The shared sensitive-name matcher (`ideas/TheGateIsNotYetAggressive.md` §2.2 item 5).
///
/// Contract under test: identifiers in any spelling are split into whole words; a vocabulary
/// term matches a contiguous run of words (or one word, singular or plural), never a substring
/// of a word; every term carries a category, a strength and at least one origin; and the
/// classification answers both questions the rules ask — "does this name mention a secret
/// anywhere" (the existing rules) and "is the secret the head of the name" (the logging rule).
@Suite("SensitiveName")
struct SensitiveNameTests {

    // MARK: - Tokenisation

    @Test("words splits every identifier spelling into lowercased whole words", arguments: [
        ("apiKey", ["api", "key"]),
        ("APIKey", ["api", "key"]),
        ("api_key", ["api", "key"]),
        ("API_KEY", ["api", "key"]),
        ("x-api-key", ["x", "api", "key"]),
        ("auth.token.expiry", ["auth", "token", "expiry"]),
        ("ANTHROPIC_API_KEY", ["anthropic", "api", "key"]),
        ("DVTSourceControlPassword", ["dvt", "source", "control", "password"]),
        ("OAuthConnection", ["o", "auth", "connection"]),
        ("sessionID", ["session", "id"]),
        ("JWTToken", ["jwt", "token"]),
        ("sha256Digest", ["sha", "256", "digest"]),
        ("token1", ["token", "1"]),
        ("SuperSecret123", ["super", "secret", "123"]),
        ("oauth2Token", ["oauth", "2", "token"]),
        ("", [String]()),
    ])
    func tokenisation(identifier: String, expected: [String]) {
        #expect(SensitiveName.words(identifier) == expected)
    }

    // MARK: - Every vocabulary term, as a bare word

    @Test("each strong term classifies into its category", arguments: [
        // credential
        ("token", SensitiveName.Category.credential),
        ("secret", .credential),
        ("credential", .credential),
        ("bearer", .credential),
        ("apikey", .credential),
        ("authtoken", .credential),
        ("accesstoken", .credential),
        ("refreshtoken", .credential),
        ("clientsecret", .credential),
        ("authorization", .credential),
        ("cookie", .credential),
        ("setcookie", .credential),
        ("jwt", .credential),
        ("otp", .credential),
        ("sessionid", .credential),
        ("authcode", .credential),
        // password
        ("password", .password),
        ("passwd", .password),
        ("passphrase", .password),
        ("passcode", .password),
        // key material
        ("privatekey", .keyMaterial),
        ("secretkey", .keyMaterial),
        ("signingkey", .keyMaterial),
        ("encryptionkey", .keyMaterial),
        ("sessionkey", .keyMaterial),
        // security parameters
        ("nonce", .securityParameter),
        ("salt", .securityParameter),
        ("iv", .securityParameter),
        ("initializationvector", .securityParameter),
        ("challenge", .securityParameter),
        ("verifier", .securityParameter),
        ("csrf", .securityParameter),
        ("session", .securityParameter),
        // personal data
        ("email", .personalData),
        ("ssn", .personalData),
        ("socialsecurity", .personalData),
        ("dob", .personalData),
        ("dateofbirth", .personalData),
        ("patientname", .personalData),
        ("mrn", .personalData),
        ("medicalrecord", .personalData),
        ("phonenumber", .personalData),
        ("homeaddress", .personalData),
        ("diagnosis", .personalData),
        ("prescription", .personalData),
    ])
    func strongTerm(word: String, category: SensitiveName.Category) {
        let result = SensitiveName.classify(word)
        #expect(result.categories == [category])
        #expect(result.headCategory == category)
        #expect(result.namesSecret == category.isSecret)
    }

    @Test("weak terms never classify alone", arguments: [
        ("key", SensitiveName.Category.keyMaterial),
        ("state", .securityParameter),
        ("pin", .password),
    ])
    func weakTerm(word: String, category: SensitiveName.Category) {
        let result = SensitiveName.classify(word)
        #expect(result.categories.isEmpty)
        #expect(result.headCategory == nil)
        #expect(result.namesSecret == false)
        #expect(result.weakCategories == [category])
        #expect(result.contains(category) == false)
        #expect(result.contains(category, includingWeak: true) == true)
    }

    @Test("the vocabulary is exactly the documented union, each term with an origin")
    func vocabularyIsPinned() {
        let spellings = SensitiveName.vocabulary.map(\.spelling)
        #expect(spellings.count == Set(spellings).count)
        #expect(spellings.count == 48)
        for term in SensitiveName.vocabulary {
            #expect(!term.origins.isEmpty, "\(term.spelling) has no origin")
        }
        let weak = SensitiveName.vocabulary.filter { $0.strength == .weak }.map(\.spelling)
        #expect(Set(weak) == ["key", "state", "pin"])
    }

    @Test("every term spelling is already normalised")
    func spellingsAreNormalised() {
        for term in SensitiveName.vocabulary {
            #expect(term.spelling == SensitiveName.normalize(term.spelling))
        }
    }

    // MARK: - Substring traps — a word containing a term is not the term

    @Test("a word that merely contains a term does not match", arguments: [
        "tokenizer", "tokenize", "tokenization", "detokenized",
        "secretary", "secretive",
        "passwordless",
        "keyboard", "keypath", "monkey",
        "salty", "basalt",
        "sessional",
        "challenger",
        "cookiecutter",
        "jwtish",
        "ivory", "emailer",
    ])
    func substringTrap(identifier: String) {
        let result = SensitiveName.classify(identifier)
        #expect(result.matches.isEmpty, "\(identifier) matched \(result.matches.map(\.term.spelling))")
        #expect(result.namesSecret == false)
    }

    @Test("a term is found as a whole word inside a longer identifier", arguments: [
        ("tokenizerToken", true),
        ("secretaryPassword", true),
        ("keyboardShortcut", false),
        ("passwordlessLogin", false),
        ("loginPassword", true),
    ])
    func wholeWordInsideIdentifier(identifier: String, secret: Bool) {
        #expect(SensitiveName.classify(identifier).namesSecret == secret)
    }

    // MARK: - Compounds are word runs

    @Test("a compound matches as a run of whole words or as one word", arguments: [
        ("apiKey", SensitiveName.Category.credential),
        ("api_key", .credential),
        ("APIKEY", .credential),
        ("ANTHROPIC_API_KEY", .credential),
        ("x-api-key", .credential),
        ("privateKey", .keyMaterial),
        ("private_key", .keyMaterial),
        ("sessionId", .credential),
        ("SESSION_ID", .credential),
        ("Set-Cookie", .credential),
        ("signingKey", .keyMaterial),
        ("dateOfBirth", .personalData),
    ])
    func compoundRun(identifier: String, head: SensitiveName.Category) {
        #expect(SensitiveName.classify(identifier).headCategory == head)
    }

    @Test("a compound does not match across a word that only starts with its tail")
    func compoundNeedsWholeWords() {
        // `api` + `keyboard` joins to `apikeyboard`, which contains `apikey` — the
        // concatenated-substring technique this matcher replaces would have matched it.
        let result = SensitiveName.classify("apiKeyboard")
        #expect(result.matches.isEmpty)
        #expect(SensitiveName.classify("privateKeypath").categories.isEmpty)
    }

    @Test("a lower-case run-together identifier matches only when it is itself a term")
    func runTogetherIdentifier() {
        #expect(SensitiveName.classify("accesstoken").headCategory == .credential)
        #expect(SensitiveName.classify("apikey").headCategory == .credential)
        // Not a term and not separable: documented limit, pinned.
        #expect(SensitiveName.classify("myapikey").matches.isEmpty)
    }

    // MARK: - Plurals

    @Test("a plural of a term matches the term", arguments: [
        ("tokens", SensitiveName.Category.credential),
        ("apiKeys", .credential),
        ("passwords", .password),
        ("cookies", .credential),
        ("cachedCredentials", .credential),
        ("nonces", .securityParameter),
    ])
    func plural(identifier: String, category: SensitiveName.Category) {
        #expect(SensitiveName.classify(identifier).categories.contains(category))
    }

    @Test("a plural is not a head: inputTokens is a count", arguments: [
        "inputTokens", "promptTokens", "tokens", "cachedCredentials",
    ])
    func pluralIsNotAHead(identifier: String) {
        let result = SensitiveName.classify(identifier)
        #expect(result.namesSecret)
        #expect(result.headCategory == nil)
    }

    @Test("keychain-secrets' origin matches plural compounds only; hardcoded-secret's matches every plural")
    func originPluralPolicy() {
        #expect(SensitiveName.classify("maxTokens", restrictedTo: .keychainSecretsRule).matches.isEmpty)
        #expect(SensitiveName.classify("maxTokens", restrictedTo: .hardcodedSecretRule).namesSecret)
        // …but its compounds, which it found by substring, match in the plural as they did.
        #expect(SensitiveName.classify("apiKeys", restrictedTo: .keychainSecretsRule).namesSecret)
        #expect(SensitiveName.classify("access_tokens", restrictedTo: .keychainSecretsRule).namesSecret)
        #expect(SensitiveName.classify("secrets", restrictedTo: .keychainSecretsRule).matches.isEmpty)
    }

    // MARK: - Head word (PublicIsAClaimAboutTheValue §4.1)

    @Test("the head of the name decides whether the name is the thing", arguments: [
        ("accessToken", SensitiveName.Category?.some(.credential)),
        ("authorizationHeader", .credential),
        ("authorizationHeaderValue", .credential),
        ("tokenString", .credential),
        ("passwordData", .password),
        ("sessionId", .credential),
        ("tokenCount", nil),
        ("tokenHashPrefix", nil),
        ("passwordLength", nil),
        ("isTokenValid", nil),
        ("tokenizerState", nil),
        ("isPasswordValid", nil),
    ])
    func headWord(identifier: String, head: SensitiveName.Category?) {
        #expect(SensitiveName.classify(identifier).headCategory == head)
    }

    @Test("a name about a secret still mentions one — the existing rules' test", arguments: [
        "tokenCount", "passwordLength", "isTokenValid", "hasSeenTokenTutorial",
        "passwordAttemptCount",
    ])
    func mentionsSecret(identifier: String) {
        let result = SensitiveName.classify(identifier)
        #expect(result.namesSecret)
        #expect(result.headCategory == nil)
    }

    // MARK: - Descriptors (ASeedIsNotASecret §3.1)

    @Test("a descriptor suffix or quantifier prefix is reported", arguments: [
        ("keyName", String?.some("name")),
        ("tokenCount", "count"),
        ("sessionExpiry", "expiry"),
        ("challengeIndex", "index"),
        ("apiKeyLabel", "label"),
        ("tokenTTL", "ttl"),
        ("maxTokens", "max"),
        ("numTokens", "num"),
        ("accessToken", nil),
        ("token", nil),
    ])
    func descriptor(identifier: String, expected: String?) {
        #expect(SensitiveName.classify(identifier).descriptor == expected)
    }

    // MARK: - Corpus cases named in the proposals

    @Test("names the proposals measured classify as they recorded", arguments: [
        // TheSecretsAreInFilesNobodyWrote §2: env keys and Xcode's credential key.
        ("ANTHROPIC_API_KEY", true),
        ("LEDGEOS_INTUIT_SANDBOX_CLIENT_SECRET", true),
        ("CLAUDE_CODE_MESSAGING_TOKEN", true),
        ("DVTSourceControlPassword", true),
        // …and `client_id` is not a secret.
        ("client_id", false),
        ("clientID", false),
        // ASeedIsNotASecret §5 test 23: `request` is not in the vocabulary.
        ("requestID", false),
        // PublicIsAClaimAboutTheValue §4.1 / §3: email is personal data, not a secret.
        ("email", false),
    ])
    func corpusCases(identifier: String, secret: Bool) {
        #expect(SensitiveName.classify(identifier).namesSecret == secret)
    }

    // MARK: - Additional terms (configuration)

    @Test("an additional term is normalised and matched like a built-in")
    func additionalTerm() {
        let extra = SensitiveName.customTerm("connectionString")
        #expect(extra.spelling == "connectionstring")
        #expect(extra.category == .credential)
        #expect(extra.strength == .strong)
        #expect(extra.origins == [.configuration])
        #expect(SensitiveName.classify("connectionString").namesSecret == false)
        #expect(SensitiveName.classify("connectionString", additionalTerms: [extra]).namesSecret)
        #expect(SensitiveName.classify("dbConnectionString", additionalTerms: [extra]).namesSecret)
        #expect(SensitiveName.classify("connection", additionalTerms: [extra]).namesSecret == false)
    }

    @Test("an empty additional term matches nothing")
    func emptyAdditionalTerm() {
        let extra = SensitiveName.customTerm("__")
        #expect(SensitiveName.classify("anything_at_all", additionalTerms: [extra]).matches.isEmpty)
    }

    // MARK: - Origin-restricted classification (the shipped rules)

    @Test("each shipped rule's origin selects exactly the words it shipped with")
    func originWordSets() {
        let hardcoded = Set(SensitiveName.terms(from: .hardcodedSecretRule).map(\.spelling))
        #expect(hardcoded == [
            "token", "secret", "credential", "apikey", "password", "privatekey",
            "authtoken", "accesstoken", "refreshtoken", "clientsecret",
        ])
        let keychain = Set(SensitiveName.terms(from: .keychainSecretsRule).map(\.spelling))
        #expect(keychain == [
            "token", "password", "passwd", "secret", "credential", "bearer",
            "apikey", "authtoken", "accesstoken", "refreshtoken", "privatekey", "clientsecret", "sessionkey",
        ])
    }

    @Test("a restricted classification ignores words outside its origin", arguments: [
        ("bearer", false, true),
        ("authorizationCode", false, false),
        ("sessionID", false, false),
        ("passphrase", false, false),
        ("apiKey", true, true),
        ("tokenizer", false, false),
    ])
    func restrictedClassification(identifier: String, hardcoded: Bool, keychain: Bool) {
        #expect(SensitiveName.classify(identifier, restrictedTo: .hardcodedSecretRule).namesSecret == hardcoded)
        #expect(SensitiveName.classify(identifier, restrictedTo: .keychainSecretsRule).namesSecret == keychain)
    }

    @Test("additional terms apply on top of a restricted vocabulary")
    func restrictedPlusAdditional() {
        let extra = SensitiveName.customTerm("jwt")
        #expect(SensitiveName.classify("jwtValue", restrictedTo: .keychainSecretsRule).namesSecret == false)
        #expect(SensitiveName.classify("jwtValue", restrictedTo: .keychainSecretsRule, additionalTerms: [extra]).namesSecret)
    }

    // MARK: - Member paths

    @Test("terminalName looks through value-carrier components", arguments: [
        (["user", "apiKey"], String?.some("apiKey")),
        (["user", "credentials", "refreshToken", "value"], "refreshToken"),
        (["token", "rawValue"], "token"),
        (["password", "utf8"], "password"),
        (["token", "description"], "token"),
        (["token", "name"], "name"),
        (["value"], "value"),
        ([String](), nil),
    ])
    func terminalName(path: [String], expected: String?) {
        #expect(SensitiveName.terminalName(ofMemberPath: path) == expected)
    }
}
