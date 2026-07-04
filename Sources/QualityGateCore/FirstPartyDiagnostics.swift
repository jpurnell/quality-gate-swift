// FirstPartyDiagnostics.swift
// QualityGateCore
//
// Scopes non-error diagnostics to first-party source so warnings originating
// in SPM dependency checkouts or build artifacts are not attributed to the
// project under audit.

import QualityGateTypes

/// Marker identifying a path that lives inside a SwiftPM build directory —
/// dependency checkouts (`.build/checkouts/...`) or build products
/// (`.build/out/...`, `.build/.../index-build/...`). These are not first-party
/// source and their warnings should not count against the project.
private let buildDirectoryMarker = "/.build/"

public extension Array where Element == Diagnostic {
    /// Returns the diagnostics with warnings and notes that originate outside
    /// first-party source removed.
    ///
    /// A diagnostic is dropped when it is a `warning` or `note` **and** it is
    /// attributable to a `.build/` location — either its ``Diagnostic/filePath``
    /// is under a build directory, or (for tools that report the artifact only
    /// in prose) its message references one. Errors are always kept so genuine
    /// build failures — including in dependencies — still surface.
    ///
    /// - Returns: The first-party-scoped diagnostics, preserving order.
    func scopedToFirstParty() -> [Diagnostic] {
        filter { diagnostic in
            guard diagnostic.severity != .error else { return true }
            if let path = diagnostic.filePath, path.contains(buildDirectoryMarker) {
                return false
            }
            // Some tools (e.g. docc) emit build-artifact warnings with no
            // filePath and the offending path only in the message.
            if diagnostic.filePath == nil, diagnostic.message.contains(buildDirectoryMarker) {
                return false
            }
            return true
        }
    }
}
