import Foundation

/// Platforms that a HIG rule can apply to.
public struct HIGPlatform: OptionSet, Sendable, Codable, Equatable {
    /// The raw bitmask value for this platform set.
    public let rawValue: UInt8

    /// Creates a platform set from a raw bitmask value.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// macOS platform flag.
    public static let macOS = HIGPlatform(rawValue: 1 << 0)
    /// iOS platform flag.
    public static let iOS = HIGPlatform(rawValue: 1 << 1)
    /// iPadOS platform flag.
    public static let iPadOS = HIGPlatform(rawValue: 1 << 2)
    /// visionOS platform flag.
    public static let visionOS = HIGPlatform(rawValue: 1 << 3)
    /// tvOS platform flag.
    public static let tvOS = HIGPlatform(rawValue: 1 << 4)
    /// watchOS platform flag.
    public static let watchOS = HIGPlatform(rawValue: 1 << 5)

    /// All Apple platforms.
    public static let all: HIGPlatform = [.macOS, .iOS, .iPadOS, .visionOS, .tvOS, .watchOS]
    /// All platforms except watchOS.
    public static let allExceptWatch: HIGPlatform = [.macOS, .iOS, .iPadOS, .visionOS, .tvOS]
    /// Desktop platforms: macOS and iPadOS.
    public static let desktop: HIGPlatform = [.macOS, .iPadOS]
    /// Large-screen platforms: macOS, iPadOS, and visionOS.
    public static let largeScreen: HIGPlatform = [.macOS, .iPadOS, .visionOS]
}

/// Severity tier for HIG rules.
public enum HIGTier: Int, Sendable, Codable {
    case structural = 1
    case modifier = 2
    case completeness = 3
}

/// Definition of a single HIG rule.
public struct HIGRuleDefinition: Sendable {
    /// Unique identifier for this rule, e.g. `"hig.settings-scene"`.
    public let id: String
    /// Human-readable description of the violation this rule detects.
    public let message: String
    /// Actionable suggestion for resolving the violation.
    public let suggestedFix: String
    /// Platforms this rule applies to.
    public let platforms: HIGPlatform
    /// Severity tier of this rule.
    public let tier: HIGTier
    /// Whether the auditor can automatically fix this violation.
    public let isAutoFixable: Bool
}

/// All HIG rules defined by the auditor.
public enum HIGRules {

    // MARK: - Tier 1: Structural

    /// Checks that macOS apps include a Settings scene for Cmd-comma.
    public static let settingsScene = HIGRuleDefinition(
        id: "hig.settings-scene",
        message: "App struct missing Settings scene. macOS apps require Cmd-comma Settings.",
        suggestedFix: "Add: Settings { SettingsView() } to your App body.",
        platforms: .macOS,
        tier: .structural,
        isAutoFixable: true
    )

    /// Checks that desktop apps expose menu bar commands via a `.commands` modifier.
    public static let menuCommands = HIGRuleDefinition(
        id: "hig.menu-commands",
        message: "App struct has no .commands { } modifier. The menu bar should expose all app commands.",
        suggestedFix: "Add .commands { } with CommandGroup or CommandMenu to your WindowGroup.",
        platforms: .desktop,
        tier: .structural,
        isAutoFixable: true
    )

    /// Suggests NavigationSplitView over NavigationStack on large-screen platforms.
    public static let navigationPattern = HIGRuleDefinition(
        id: "hig.navigation-pattern",
        message: "NavigationStack used — consider NavigationSplitView for sidebar-based navigation on larger displays.",
        suggestedFix: "Use NavigationSplitView with a sidebar for hierarchical navigation.",
        platforms: .largeScreen,
        tier: .structural,
        isAutoFixable: false
    )

    /// Checks that `.windowResizability(.contentSize)` is paired with frame constraints.
    public static let windowResizability = HIGRuleDefinition(
        id: "hig.window-resizability",
        message: "WindowGroup uses .windowResizability(.contentSize) without min/max frame constraints.",
        suggestedFix: "Add .frame(minWidth:maxWidth:minHeight:maxHeight:) or use .windowResizability(.automatic).",
        platforms: .largeScreen,
        tier: .structural,
        isAutoFixable: false
    )

    /// Flags tab bars that contain action buttons instead of navigation destinations.
    public static let tabBarNavigation = HIGRuleDefinition(
        id: "hig.tab-bar-navigation",
        message: "TabView appears to contain action buttons rather than navigation destinations.",
        suggestedFix: "Use a tab bar for navigation between sections, not for triggering actions.",
        platforms: [.iOS, .iPadOS, .tvOS, .visionOS],
        tier: .structural,
        isAutoFixable: false
    )

    /// Flags opaque backgrounds that override the visionOS system glass material.
    public static let glassBackground = HIGRuleDefinition(
        id: "hig.glass-background",
        message: "Root view applies opaque background, overriding the system glass material.",
        suggestedFix: "Remove the opaque .background() to retain the visionOS glass appearance.",
        platforms: .visionOS,
        tier: .structural,
        isAutoFixable: false
    )

    // MARK: - Tier 2: Modifier

    /// Checks that toolbar buttons include a `.help()` tooltip for pointer hover.
    public static let toolbarTooltips = HIGRuleDefinition(
        id: "hig.toolbar-tooltips",
        message: "Button in ToolbarItem missing .help() tooltip for pointer hover feedback.",
        suggestedFix: "Add .help(\"Description\") to the toolbar button.",
        platforms: .desktop,
        tier: .modifier,
        isAutoFixable: true
    )

    /// Checks that primary toolbar actions have a `.keyboardShortcut()` modifier.
    public static let keyboardShortcuts = HIGRuleDefinition(
        id: "hig.keyboard-shortcuts",
        message: "Primary toolbar action missing .keyboardShortcut() modifier.",
        suggestedFix: "Add .keyboardShortcut() for keyboard-driven workflows.",
        platforms: [.macOS, .iPadOS, .visionOS],
        tier: .modifier,
        isAutoFixable: true
    )

    /// Checks that list items provide a `.contextMenu` for right-click or long-press actions.
    public static let contextMenus = HIGRuleDefinition(
        id: "hig.context-menus",
        message: "List items missing .contextMenu modifier for right-click / long-press actions.",
        suggestedFix: "Add .contextMenu { } with relevant actions to list items.",
        platforms: .allExceptWatch,
        tier: .modifier,
        isAutoFixable: true
    )

    /// Flags hardcoded Color literals in view bodies; prefer semantic colors.
    public static let semanticColors = HIGRuleDefinition(
        id: "hig.semantic-colors",
        message: "Hardcoded Color literal in View body. Use semantic colors for Dark Mode and accessibility.",
        suggestedFix: "Use .tint, .primary, .secondary, or Color(\"AssetName\") instead.",
        platforms: .all,
        tier: .modifier,
        isAutoFixable: true
    )

    /// Checks that ToolbarItem specifies an explicit `placement:` argument.
    public static let toolbarPlacement = HIGRuleDefinition(
        id: "hig.toolbar-placement",
        message: "ToolbarItem without explicit placement: argument.",
        suggestedFix: "Add placement: .primaryAction, .secondaryAction, .navigation, etc.",
        platforms: [.macOS, .iOS, .iPadOS],
        tier: .modifier,
        isAutoFixable: true
    )

    /// Flags custom selection colors that ignore the macOS inactive-window state.
    public static let inactiveWindowState = HIGRuleDefinition(
        id: "hig.inactive-window-state",
        message: "View uses custom selection colors but never reads controlActiveState environment.",
        suggestedFix: "Read @Environment(\\.controlActiveState) to adjust appearance in inactive windows.",
        platforms: .macOS,
        tier: .modifier,
        isAutoFixable: false
    )

    /// Flags unconditional tab bar hiding outside of a modal context.
    public static let tabBarVisibility = HIGRuleDefinition(
        id: "hig.tab-bar-visibility",
        message: "Tab bar hidden unconditionally outside modal context.",
        suggestedFix: "Keep the tab bar visible so people know where they are in the app.",
        platforms: [.iOS, .iPadOS],
        tier: .modifier,
        isAutoFixable: false
    )

    /// Flags custom focus effects that override the tvOS system parallax behavior.
    public static let focusSystem = HIGRuleDefinition(
        id: "hig.focus-system",
        message: "Custom focus effect overrides system parallax on tvOS.",
        suggestedFix: "Rely on system-provided focus effects for consistency.",
        platforms: .tvOS,
        tier: .modifier,
        isAutoFixable: false
    )

    // MARK: - Tier 3: Completeness

    /// Suggests adding multi-window support when only a single WindowGroup exists.
    public static let multiWindow = HIGRuleDefinition(
        id: "hig.multi-window",
        message: "App has one WindowGroup and no openWindow usage. Consider multi-window support.",
        suggestedFix: "Add @Environment(\\.openWindow) and additional WindowGroup scenes.",
        platforms: .largeScreen,
        tier: .completeness,
        isAutoFixable: false
    )

    /// Checks that deletable lists also support drag-and-drop reordering.
    public static let dragDrop = HIGRuleDefinition(
        id: "hig.drag-drop",
        message: "List supports deletion but not drag-and-drop reordering.",
        suggestedFix: "Add .draggable() and .dropDestination() for drag-and-drop support.",
        platforms: [.macOS, .iOS, .iPadOS, .visionOS],
        tier: .completeness,
        isAutoFixable: false
    )

    /// Flags views with state mutations that never access the undo manager.
    public static let undoSupport = HIGRuleDefinition(
        id: "hig.undo-support",
        message: "View with @State mutations but no undoManager access.",
        suggestedFix: "Read @Environment(\\.undoManager) for reversible user actions.",
        platforms: .allExceptWatch,
        tier: .completeness,
        isAutoFixable: false
    )

    /// Checks that custom interactive views include `.focusable()` for keyboard access.
    public static let focusSupport = HIGRuleDefinition(
        id: "hig.focus-support",
        message: "Custom interactive view (onTapGesture) without .focusable() modifier.",
        suggestedFix: "Add .focusable() for Full Keyboard Access support.",
        platforms: [.macOS, .iPadOS, .tvOS, .visionOS],
        tier: .completeness,
        isAutoFixable: false
    )

    /// Checks that macOS apps with menu commands include a Help menu.
    public static let helpMenu = HIGRuleDefinition(
        id: "hig.help-menu",
        message: "App has menu commands but no Help menu.",
        suggestedFix: "Add CommandGroup(replacing: .help) { } or CommandMenu(\"Help\") { }.",
        platforms: .macOS,
        tier: .completeness,
        isAutoFixable: false
    )

    /// Checks that macOS apps with menu commands include Window management items.
    public static let windowMenu = HIGRuleDefinition(
        id: "hig.window-menu",
        message: "App has menu commands but no Window-related CommandGroup.",
        suggestedFix: "Add CommandGroup(replacing: .windowArrangement) or Window menu items.",
        platforms: .macOS,
        tier: .completeness,
        isAutoFixable: false
    )

    /// Suggests `.tabViewStyle(.sidebarAdaptable)` for iPadOS TabViews with many tabs.
    public static let sidebarAdaptable = HIGRuleDefinition(
        id: "hig.sidebar-adaptable",
        message: "TabView with many tabs — consider .tabViewStyle(.sidebarAdaptable) on iPadOS.",
        suggestedFix: "Add .tabViewStyle(.sidebarAdaptable) for complex navigation hierarchies.",
        platforms: .iPadOS,
        tier: .completeness,
        isAutoFixable: false
    )

    /// Checks that volumetric visionOS windows specify a `.defaultSize()` modifier.
    public static let volumeSizing = HIGRuleDefinition(
        id: "hig.volume-sizing",
        message: "Volumetric WindowGroup without .defaultSize() modifier.",
        suggestedFix: "Add .defaultSize(width:height:depth:) to set appropriate initial volume size.",
        platforms: .visionOS,
        tier: .completeness,
        isAutoFixable: false
    )

    /// Suggests using `.ornament()` for controls in visionOS volumetric windows.
    public static let ornamentUsage = HIGRuleDefinition(
        id: "hig.ornament-usage",
        message: "Volumetric window with toolbar items but no .ornament() modifier.",
        suggestedFix: "Consider using .ornament() for high-value controls in volumes.",
        platforms: .visionOS,
        tier: .completeness,
        isAutoFixable: false
    )

    /// Exemption comment prefix recognized by the auditor.
    public static let exemptionPrefix = "HIG-EXEMPT:"
}
