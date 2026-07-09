/// A universal accessibility principle that a rule enforces, anchored to Apple's HIG.
///
/// Accessibility is a cross-frontend concern (SwiftUI, CLI, and beyond), but every
/// principle is grounded in Apple's Human Interface Guidelines — the gold standard — via
/// ``higAnchor``. A rule on any frontend maps to one of these principles and inherits its
/// HIG citation, so the standard stays consistent even when the detection mechanism
/// differs per frontend.
public enum AccessibilityPrinciple: Sendable {
    /// Non-text content must expose a text/accessible name (e.g. a VoiceOver label).
    case textAlternative
    /// Text must scale to the user's size preference (Dynamic Type).
    case scalableText
    /// Motion must honor the Reduce Motion accessibility setting.
    case respectMotionPref
    /// The user's visual/appearance preferences (color, contrast) must be honored.
    case respectVisualPrefs
    /// Custom interactive elements must be operable and identifiable by assistive tech
    /// (e.g. a tappable view needs a button trait so VoiceOver announces it as actionable).
    case operableAltInput

    /// A concise citation of the Apple HIG guidance this principle is grounded in.
    ///
    /// Always non-empty: a rule cannot claim a principle without naming its HIG basis.
    public var higAnchor: String {
        switch self {
        case .textAlternative:
            return "Apple HIG — VoiceOver: provide alternative labels for all key interface elements"
        case .scalableText:
            return "Apple HIG — Typography: use built-in text styles so text supports Dynamic Type"
        case .respectMotionPref:
            return "Apple HIG — Accessibility: reduce automatic and repetitive animations when Reduce Motion is on"
        case .respectVisualPrefs:
            return "Apple HIG — Accessibility: adapt to the user's settings; honor color/appearance preferences (CLI: the NO_COLOR convention)"
        case .operableAltInput:
            return "Apple HIG — VoiceOver: add labels and traits to any custom elements your app defines"
        }
    }
}
