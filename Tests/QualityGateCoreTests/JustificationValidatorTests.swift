import Foundation
import Testing
@testable import QualityGateCore

@Suite("JustificationValidator")
struct JustificationValidatorTests {
    let validator = JustificationValidator()

    // MARK: - Word count boundary

    @Test("7 words is too short")
    func sevenWordsIsTooShort() {
        let text = "Justification: one two three four five six seven"
        let result = validator.validate(text)
        guard case .tooShort(let count) = result else {
            Issue.record("Expected .tooShort, got \(result)")
            return
        }
        #expect(count == 7)
    }

    @Test("8 words is valid")
    func eightWordsIsValid() {
        let text = "Justification: one two three four five six seven eight"
        let result = validator.validate(text)
        #expect(result == .valid)
    }

    @Test("0 words after keyword is too short")
    func emptyPayloadIsTooShort() {
        let text = "Justification:"
        let result = validator.validate(text)
        guard case .tooShort(let count) = result else {
            Issue.record("Expected .tooShort, got \(result)")
            return
        }
        #expect(count == 0)
    }

    // MARK: - Denylist phrases

    @Test("Rejects 'safe' as generic")
    func rejectsSafe() {
        let text = "Justification: safe"
        let result = validator.validate(text)
        guard case .generic(let phrase) = result else {
            Issue.record("Expected .generic, got \(result)")
            return
        }
        #expect(phrase == "safe")
    }

    @Test("Rejects 'works fine' as generic")
    func rejectsWorksFine() {
        let text = "Justification: works fine"
        let result = validator.validate(text)
        guard case .generic(let phrase) = result else {
            Issue.record("Expected .generic, got \(result)")
            return
        }
        #expect(phrase == "works fine")
    }

    @Test("Rejects 'trust me' as generic")
    func rejectsTrustMe() {
        let text = "Justification: trust me"
        let result = validator.validate(text)
        guard case .generic(let phrase) = result else {
            Issue.record("Expected .generic, got \(result)")
            return
        }
        #expect(phrase == "trust me")
    }

    @Test("Rejects 'will fix later' as generic")
    func rejectsWillFixLater() {
        let text = "Justification: will fix later"
        let result = validator.validate(text)
        guard case .generic(let phrase) = result else {
            Issue.record("Expected .generic, got \(result)")
            return
        }
        #expect(phrase == "will fix later")
    }

    // MARK: - Keyword extraction

    @Test("Strips keyword prefix before validation")
    func stripsKeywordPrefix() {
        let text = "Justification: synchronized via NSLock in all public methods ensuring thread safety"
        let result = validator.validate(text)
        #expect(result == .valid)
    }

    @Test("Works with custom keyword")
    func customKeyword() {
        let text = "SAFETY: protected by actor isolation ensuring all mutations happen on MainActor exclusively"
        let result = validator.validate(text, keyword: "SAFETY:")
        #expect(result == .valid)
    }

    @Test("Handles text without keyword")
    func noKeywordInText() {
        let text = "synchronized via NSLock in all public methods ensuring thread safety"
        let result = validator.validate(text)
        #expect(result == .valid)
    }

    // MARK: - Duplicate detection

    @Test("First occurrence is valid, second is duplicate")
    func duplicateDetection() {
        var seen: Set<String> = []
        let text = "Justification: synchronized via NSLock in all public methods ensuring thread safety"
        let first = validator.validateForDuplicates(text, seen: &seen)
        #expect(first == .valid)
        let second = validator.validateForDuplicates(text, seen: &seen)
        #expect(second == .duplicate)
    }

    @Test("Different justifications are not duplicates")
    func differentTextsNotDuplicate() {
        var seen: Set<String> = []
        let text1 = "Justification: synchronized via NSLock in all public methods ensuring thread safety"
        let text2 = "Justification: protected by actor isolation with exclusive access via DispatchQueue barrier"
        let first = validator.validateForDuplicates(text1, seen: &seen)
        #expect(first == .valid)
        let second = validator.validateForDuplicates(text2, seen: &seen)
        #expect(second == .valid)
    }

    @Test("Duplicate check skips validation failures")
    func duplicateCheckSkipsInvalid() {
        var seen: Set<String> = []
        let text = "Justification: safe"
        let first = validator.validateForDuplicates(text, seen: &seen)
        #expect(first == .generic)
        let second = validator.validateForDuplicates(text, seen: &seen)
        #expect(second == .generic)
    }
}
