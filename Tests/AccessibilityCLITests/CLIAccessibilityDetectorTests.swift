import Testing
@testable import AccessibilityCLI

/// `honorsColorPreference` decides whether every `a11y.cli.*` rule stays silent for a whole
/// file, so what counts as a marker is the difference between a rule that works and one that
/// anything can switch off by accident.
@Suite("CLIAccessibilityDetector — color-preference markers")
struct CLIAccessibilityMarkerTests {

    // MARK: - Genuine guards are recognised

    @Test("Reading NO_COLOR counts as honoring the preference")
    func noColorEnvironmentRead() {
        let source = #"let plain = ProcessInfo.processInfo.environment["NO_COLOR"] != nil"#
        #expect(CLIAccessibilityDetector.honorsColorPreference(in: source))
    }

    @Test("An isatty call counts as honoring the preference")
    func isattyCall() {
        #expect(CLIAccessibilityDetector.honorsColorPreference(in: "guard isatty(STDOUT_FILENO) != 0 else { return }"))
    }

    @Test("Reading the TERM variable counts as honoring the preference")
    func termEnvironmentRead() {
        let source = #"let term = ProcessInfo.processInfo.environment["TERM"] ?? "dumb""#
        #expect(CLIAccessibilityDetector.honorsColorPreference(in: source))
    }

    @Test("A --no-color flag counts as honoring the preference")
    func noColorFlag() {
        #expect(CLIAccessibilityDetector.honorsColorPreference(in: #"case "--no-color": plain = true"#))
    }

    // MARK: - Words that merely contain a marker do not count

    @Test("Prose mentioning TERMINAL is not a TERM guard")
    func terminalProseIsNotAGuard() {
        let source = "/// Manages the TERMINAL alternate screen buffer."
        #expect(!CLIAccessibilityDetector.honorsColorPreference(in: source))
    }

    @Test("A TERMINATED status is not a TERM guard")
    func terminatedIsNotAGuard() {
        #expect(!CLIAccessibilityDetector.honorsColorPreference(in: "case TERMINATED"))
    }

    @Test("A file with no marker at all does not honor the preference")
    func noMarkers() {
        #expect(!CLIAccessibilityDetector.honorsColorPreference(in: "let count = 1"))
    }
}
