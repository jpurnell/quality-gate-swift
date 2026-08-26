import Foundation
#if canImport(os)
import os
#endif

/// Detects target platforms from Package.swift and source file conditionals.
public struct PlatformDetector: Sendable {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "PlatformDetector")

    /// Detect platforms declared in a Package.swift file.
    ///
    /// Parses the `platforms:` array for entries like `.macOS(.v15)`, `.iOS(.v17)`, etc.
    public static func detectFromPackageManifest(at projectPath: String) -> HIGPlatform {
        let manifestPath = (projectPath as NSString).appendingPathComponent("Package.swift")
        let contents: String
        do {
            contents = try String(contentsOfFile: manifestPath, encoding: .utf8)
        } catch {
            logger.warning("Could not read Package.swift for platform detection, defaulting to all platforms: \(error.localizedDescription, privacy: .public)")
            return .all
        }
        return detectFromManifestContents(contents)
    }

    /// Parse manifest content for platform declarations.
    static func detectFromManifestContents(_ contents: String) -> HIGPlatform {
        var platforms: HIGPlatform = []

        if contents.contains(".macOS(") || contents.contains(".macOS,") {
            platforms.insert(.macOS)
        }
        if contents.contains(".iOS(") || contents.contains(".iOS,") {
            platforms.insert(.iOS)
            platforms.insert(.iPadOS)
        }
        if contents.contains(".visionOS(") || contents.contains(".visionOS,") {
            platforms.insert(.visionOS)
        }
        if contents.contains(".tvOS(") || contents.contains(".tvOS,") {
            platforms.insert(.tvOS)
        }
        if contents.contains(".watchOS(") || contents.contains(".watchOS,") {
            platforms.insert(.watchOS)
        }

        if platforms.isEmpty {
            return .all
        }
        return platforms
    }

    /// The platforms an `App` file definitively targets, or `nil` when the file
    /// carries no marker that rules a platform in or out.
    ///
    /// The project-wide platform set comes from `Package.swift`. A repository with
    /// no manifest at its root — an Xcode project, or a monorepo of packages — falls
    /// back to ``HIGPlatform/all``, which contains macOS, so every `App` struct was
    /// being audited against macOS-only structural rules. `Settings` is a macOS-only
    /// scene; asking a watchOS app for one asks for code that will not compile.
    ///
    /// Only markers that cannot appear on another platform are used, so a definite
    /// answer here is safe to prefer over the project-wide default. A file that
    /// names several platforms returns all of them; one that names none returns
    /// `nil` and leaves the caller's default in place.
    public static func detectAppPlatform(_ source: String) -> HIGPlatform? {
        var platforms: HIGPlatform = []

        // WatchKit and the WK delegate adaptors exist only on watchOS.
        if source.contains("os(watchOS)")
            || source.contains("import WatchKit")
            || source.contains("WKApplicationDelegateAdaptor")
            || source.contains("WKExtensionDelegateAdaptor") {
            platforms.insert(.watchOS)
        }

        // ImmersiveSpace and RealityView are visionOS-only scene/view types.
        if source.contains("os(visionOS)")
            || source.contains("ImmersiveSpace")
            || source.contains("RealityView") {
            platforms.insert(.visionOS)
        }

        // AppKit, the NS adaptor and MenuBarExtra are macOS-only.
        if source.contains("os(macOS)")
            || source.contains("import AppKit")
            || source.contains("NSApplicationDelegateAdaptor")
            || source.contains("MenuBarExtra") {
            platforms.insert(.macOS)
        }

        // UIKit, the UI adaptor and ActivityKit do not build for macOS or watchOS.
        if source.contains("os(iOS)")
            || source.contains("import UIKit")
            || source.contains("UIApplicationDelegateAdaptor")
            || source.contains("import ActivityKit") {
            platforms.insert(.iOS)
            platforms.insert(.iPadOS)
        }

        if source.contains("os(tvOS)") {
            platforms.insert(.tvOS)
        }

        return platforms.isEmpty ? nil : platforms
    }

    /// Detect platform-conditional code in a Swift source file.
    ///
    /// Checks for `#if os(macOS)`, `#if os(iOS)`, etc. to determine which
    /// platforms a specific block of code targets.
    public static func detectFromSource(_ source: String) -> HIGPlatform {
        var platforms: HIGPlatform = []

        if source.contains("#if os(macOS)") || source.contains("canImport(AppKit)") {
            platforms.insert(.macOS)
        }
        if source.contains("#if os(iOS)") || source.contains("canImport(UIKit)") {
            platforms.insert(.iOS)
            platforms.insert(.iPadOS)
        }
        if source.contains("#if os(visionOS)") {
            platforms.insert(.visionOS)
        }
        if source.contains("#if os(tvOS)") {
            platforms.insert(.tvOS)
        }
        if source.contains("#if os(watchOS)") {
            platforms.insert(.watchOS)
        }

        return platforms
    }
}
