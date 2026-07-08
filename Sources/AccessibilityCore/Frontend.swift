/// A UI frontend whose source can be audited for accessibility.
///
/// Accessibility is a universal principle, but the concrete signals that reveal a
/// violation are frontend-specific. `Frontend` identifies which detector(s) apply to a
/// given source file so the auditor can stay one engine across SwiftUI, CLI, and
/// (eventually) web and Android surfaces.
public enum Frontend: String, Sendable, CaseIterable, Codable {
    /// Apple SwiftUI views (`import SwiftUI`).
    case swiftUI = "swiftui"
    /// Command-line output (SwiftCLIKit / ArgumentParser terminal writes).
    case cli
    /// Web UI compiled via SwiftWASM (`import JavaScriptKit`). Detector stubbed in v1.
    case web
    // NOTE: `.android` is intentionally not declared yet. Android accessibility is
    // detected out-of-process (Android Lint over Compose), off by default, and no
    // in-repo code constructs it — declaring an unused case would trip the
    // UnreachableCodeAuditor. The case is (re)introduced in the Android slice
    // together with the orchestrator/config code that consumes it.
}
