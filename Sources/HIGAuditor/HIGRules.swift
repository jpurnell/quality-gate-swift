import Foundation

/// Platforms that a HIG rule can apply to.
public struct HIGPlatform: OptionSet, Sendable, Codable, Equatable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let macOS = HIGPlatform(rawValue: 1 << 0)
    public static let iOS = HIGPlatform(rawValue: 1 << 1)
    public static let iPadOS = HIGPlatform(rawValue: 1 << 2)
    public static let visionOS = HIGPlatform(rawValue: 1 << 3)
    public static let tvOS = HIGPlatform(rawValue: 1 << 4)
    public static let watchOS = HIGPlatform(rawValue: 1 << 5)

    public static let all: HIGPlatform = [.macOS, .iOS, .iPadOS, .visionOS, .tvOS, .watchOS]
    public static let allExceptWatch: HIGPlatform = [.macOS, .iOS, .iPadOS, .visionOS, .tvOS]
    public static let desktop: HIGPlatform = [.macOS, .iPadOS]
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
    public let id: String
    public let message: String
    public let suggestedFix: String
    public let platforms: HIGPlatform
    public let tier: HIGTier
    public let isAutoFixable: Bool
}

/// All HIG rules defined by the auditor.
public enum HIGRules {

    // MARK: - Tier 1: Structural

    public static let settingsScene = HIGRuleDefinition(
        id: "hig.settings-scene",
        message: "App struct missing Settings scene. macOS apps require Cmd-comma Settings.",
        suggestedFix: "Add: Settings { SettingsView() } to your App body.",
        platforms: .macOS,
        tier: .structural,
        isAutoFixable: true
    )

    public static let menuCommands = HIGRuleDefinition(
        id: "hig.menu-commands",
        message: "App struct has no .commands { } modifier. The menu bar should expose all app commands.",
        suggestedFix: "Add .commands { } with CommandGroup or CommandMenu to your WindowGroup.",
        platforms: .desktop,
        tier: .structural,
        isAutoFixable: true
    )

    public static let navigationPattern = HIGRuleDefinition(
        id: "hig.navigation-pattern",
        message: "NavigationStack used — consider NavigationSplitView for sidebar-based navigation on larger displays.",
        suggestedFix: "Use NavigationSplitView with a sidebar for hierarchical navigation.",
        platforms: .largeScreen,
        tier: .structural,
        isAutoFixable: false
    )

    public static let windowResizability = HIGRuleDefinition(
        id: "hig.window-resizability",
        message: "WindowGroup uses .windowResizability(.contentSize) without min/max frame constraints.",
        suggestedFix: "Add .frame(minWidth:maxWidth:minHeight:maxHeight:) or use .windowResizability(.automatic).",
        platforms: .largeScreen,
        tier: .structural,
        isAutoFixable: false
    )

    public static let tabBarNavigation = HIGRuleDefinition(
        id: "hig.tab-bar-navigation",
        message: "TabView appears to contain action buttons rather than navigation destinations.",
        suggestedFix: "Use a tab bar for navigation between sections, not for triggering actions.",
        platforms: [.iOS, .iPadOS, .tvOS, .visionOS],
        tier: .structural,
        isAutoFixable: false
    )

    public static let glassBackground = HIGRuleDefinition(
        id: "hig.glass-background",
        message: "Root view applies opaque background, overriding the system glass material.",
        suggestedFix: "Remove the opaque .background() to retain the visionOS glass appearance.",
        platforms: .visionOS,
        tier: .structural,
        isAutoFixable: false
    )

    // MARK: - Tier 2: Modifier

    public static let toolbarTooltips = HIGRuleDefinition(
        id: "hig.toolbar-tooltips",
        message: "Button in ToolbarItem missing .help() tooltip for pointer hover feedback.",
        suggestedFix: "Add .help(\"Description\") to the toolbar button.",
        platforms: .desktop,
        tier: .modifier,
        isAutoFixable: true
    )

    public static let keyboardShortcuts = HIGRuleDefinition(
        id: "hig.keyboard-shortcuts",
        message: "Primary toolbar action missing .keyboardShortcut() modifier.",
        suggestedFix: "Add .keyboardShortcut() for keyboard-driven workflows.",
        platforms: [.macOS, .iPadOS, .visionOS],
        tier: .modifier,
        isAutoFixable: true
    )

    public static let contextMenus = HIGRuleDefinition(
        id: "hig.context-menus",
        message: "List items missing .contextMenu modifier for right-click / long-press actions.",
        suggestedFix: "Add .contextMenu { } with relevant actions to list items.",
        platforms: .allExceptWatch,
        tier: .modifier,
        isAutoFixable: true
    )

    public static let semanticColors = HIGRuleDefinition(
        id: "hig.semantic-colors",
        message: "Hardcoded Color literal in View body. Use semantic colors for Dark Mode and accessibility.",
        suggestedFix: "Use .tint, .primary, .secondary, or Color(\"AssetName\") instead.",
        platforms: .all,
        tier: .modifier,
        isAutoFixable: true
    )

    public static let toolbarPlacement = HIGRuleDefinition(
        id: "hig.toolbar-placement",
        message: "ToolbarItem without explicit placement: argument.",
        suggestedFix: "Add placement: .primaryAction, .secondaryAction, .navigation, etc.",
        platforms: [.macOS, .iOS, .iPadOS],
        tier: .modifier,
        isAutoFixable: true
    )

    public static let inactiveWindowState = HIGRuleDefinition(
        id: "hig.inactive-window-state",
        message: "View uses custom selection colors but never reads controlActiveState environment.",
        suggestedFix: "Read @Environment(\\.controlActiveState) to adjust appearance in inactive windows.",
        platforms: .macOS,
        tier: .modifier,
        isAutoFixable: false
    )

    public static let tabBarVisibility = HIGRuleDefinition(
        id: "hig.tab-bar-visibility",
        message: "Tab bar hidden unconditionally outside modal context.",
        suggestedFix: "Keep the tab bar visible so people know where they are in the app.",
        platforms: [.iOS, .iPadOS],
        tier: .modifier,
        isAutoFixable: false
    )

    public static let focusSystem = HIGRuleDefinition(
        id: "hig.focus-system",
        message: "Custom focus effect overrides system parallax on tvOS.",
        suggestedFix: "Rely on system-provided focus effects for consistency.",
        platforms: .tvOS,
        tier: .modifier,
        isAutoFixable: false
    )

    // MARK: - Tier 3: Completeness

    public static let multiWindow = HIGRuleDefinition(
        id: "hig.multi-window",
        message: "App has one WindowGroup and no openWindow usage. Consider multi-window support.",
        suggestedFix: "Add @Environment(\\.openWindow) and additional WindowGroup scenes.",
        platforms: .largeScreen,
        tier: .completeness,
        isAutoFixable: false
    )

    public static let dragDrop = HIGRuleDefinition(
        id: "hig.drag-drop",
        message: "List supports deletion but not drag-and-drop reordering.",
        suggestedFix: "Add .draggable() and .dropDestination() for drag-and-drop support.",
        platforms: [.macOS, .iOS, .iPadOS, .visionOS],
        tier: .completeness,
        isAutoFixable: false
    )

    public static let undoSupport = HIGRuleDefinition(
        id: "hig.undo-support",
        message: "View with @State mutations but no undoManager access.",
        suggestedFix: "Read @Environment(\\.undoManager) for reversible user actions.",
        platforms: .allExceptWatch,
        tier: .completeness,
        isAutoFixable: false
    )

    public static let focusSupport = HIGRuleDefinition(
        id: "hig.focus-support",
        message: "Custom interactive view (onTapGesture) without .focusable() modifier.",
        suggestedFix: "Add .focusable() for Full Keyboard Access support.",
        platforms: [.macOS, .iPadOS, .tvOS, .visionOS],
        tier: .completeness,
        isAutoFixable: false
    )

    public static let helpMenu = HIGRuleDefinition(
        id: "hig.help-menu",
        message: "App has menu commands but no Help menu.",
        suggestedFix: "Add CommandGroup(replacing: .help) { } or CommandMenu(\"Help\") { }.",
        platforms: .macOS,
        tier: .completeness,
        isAutoFixable: false
    )

    public static let windowMenu = HIGRuleDefinition(
        id: "hig.window-menu",
        message: "App has menu commands but no Window-related CommandGroup.",
        suggestedFix: "Add CommandGroup(replacing: .windowArrangement) or Window menu items.",
        platforms: .macOS,
        tier: .completeness,
        isAutoFixable: false
    )

    public static let sidebarAdaptable = HIGRuleDefinition(
        id: "hig.sidebar-adaptable",
        message: "TabView with many tabs — consider .tabViewStyle(.sidebarAdaptable) on iPadOS.",
        suggestedFix: "Add .tabViewStyle(.sidebarAdaptable) for complex navigation hierarchies.",
        platforms: .iPadOS,
        tier: .completeness,
        isAutoFixable: false
    )

    public static let volumeSizing = HIGRuleDefinition(
        id: "hig.volume-sizing",
        message: "Volumetric WindowGroup without .defaultSize() modifier.",
        suggestedFix: "Add .defaultSize(width:height:depth:) to set appropriate initial volume size.",
        platforms: .visionOS,
        tier: .completeness,
        isAutoFixable: false
    )

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
