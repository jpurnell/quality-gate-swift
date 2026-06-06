import Foundation
import os

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
