import Foundation

extension ReleasePreflight {

    /// Does this release have the soak it needs?
    ///
    /// Pure: the clock is passed in, as `now`, and the verdict is recomputed from the samples, so a result file's own
    /// verdict can neither pass a soak that grew nor fail one that did not. Only the tag classes in
    /// ``SoakRelease/requiredFor`` block; any other tag gets a note saying whether a result exists.
    ///
    /// - Parameters:
    ///   - result: The sealed result, or `nil` if there is none.
    ///   - currentDigest: The digest of the source being released.
    ///   - tag: The version being cut, such as `v2.1.0`.
    ///   - release: The requirement.
    ///   - now: The current time.
    public static func soak(
        result: SoakResult?, currentDigest: String, tag: String, release: SoakRelease, now: Date
    ) -> SoakReport {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        var findings: [Finding] = []
        var notes: [Finding] = []

        if let waiver = release.waiver, waiver.version.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) == version {
            notes.append(Finding(
                ruleId: "release.soak-waived",
                message: "The soak for \(version) is waived: \(waiver.reason) (\(waiver.date)).",
                remedy: "None; the waiver names this version only and does not carry to the next."))
            return SoakReport(findings: [], notes: notes)
        }

        let required = SoakTagClass(tag: tag).map(release.requiredFor.contains) ?? false
        guard let result else {
            if required {
                findings.append(Finding(
                    ruleId: "release.soak-missing",
                    message: "\(tag) requires a soak and no result exists.",
                    remedy: "Run the package's soak for at least \(release.minSeconds / 60) minutes, then `quality-gate soak seal`."))
            } else {
                notes.append(Finding(
                    ruleId: "release.soak-advised", message: "No soak result exists for \(tag); a soak is advised for this tag but not required.",
                    remedy: "Optional: run the package's soak and `quality-gate soak seal`."))
            }
            return SoakReport(findings: findings, notes: notes)
        }
        guard required else {
            notes.append(Finding(
                ruleId: "release.soak-advised", message: "A soak result exists for \(tag); a soak is advised for this tag but not required, so it was not judged.",
                remedy: "None."))
            return SoakReport(findings: [], notes: notes)
        }

        guard result.schemaVersion == SoakResult.currentSchemaVersion, result.intervalSeconds > 0 else {
            findings.append(Finding(
                ruleId: "release.soak-unreadable",
                message: "The soak result is in schema \(result.schemaVersion) or has no sampling interval; this gate reads schema \(SoakResult.currentSchemaVersion).",
                remedy: "Seal the soak again with this version of quality-gate."))
            return SoakReport(findings: findings, notes: notes)
        }

        if result.sourceDigest != currentDigest {
            findings.append(Finding(
                ruleId: "release.soak-stale-source",
                message: "The soak measured different source than is being released.",
                remedy: "Soak the source being released, then seal it again."))
        }
        let tooShort = result.durationSeconds < release.minSeconds
        if tooShort {
            findings.append(Finding(
                ruleId: "release.soak-too-short",
                message: "The soak ran \(result.durationSeconds / 60) minutes; at least \(release.minSeconds / 60) are required.",
                remedy: "Run the soak longer: the first \(Int(release.limits.preWarmSeconds / 60)) minutes are not judged."))
        }
        let expected = Double(result.durationSeconds) / Double(result.intervalSeconds)
        let sparse = Double(result.samples.count) < 0.8 * expected
        if sparse {
            findings.append(Finding(
                ruleId: "release.soak-sparse",
                message: "The soak holds \(result.samples.count) samples; its duration and interval promise about \(Int(expected)).",
                remedy: "Check that the sampler kept running, and seal a complete run."))
        }
        if now.timeIntervalSince(result.endedAt) > Double(release.maxAgeDays) * 86_400 {
            findings.append(Finding(
                ruleId: "release.soak-old",
                message: "The soak ended more than \(release.maxAgeDays) days ago.",
                remedy: "Soak again close to the release."))
        }

        let recomputed = SoakJudgement.judge(samples: result.samples, architecture: result.architecture, limits: release.limits)
        switch recomputed.verdict {
        case .pass:
            break
        case .fail(let reasons):
            findings.append(Finding(
                ruleId: "release.soak-grew", message: reasons.joined(separator: "; ") + ".",
                remedy: "Find what grows: compare footprint categories and the descriptor count across the window."))
        case .inconclusive(let reason):
            if !tooShort && !sparse {
                findings.append(Finding(
                    ruleId: "release.soak-unjudged", message: "The soak could not be judged: \(reason).",
                    remedy: "Run longer, or fix the sampling, so the judged window is covered."))
            }
        }
        if result.sealed.verdict != recomputed.verdict {
            findings.append(Finding(
                ruleId: "release.soak-verdict-forged",
                message: "The result's recorded verdict disagrees with the one recomputed from its samples.",
                remedy: "Seal the soak again; a result file is only ever written by `quality-gate soak seal`."))
        }
        if release.requireDrain, result.drain.map({ $0.exitCode != 0 }) ?? true {
            findings.append(Finding(
                ruleId: "release.soak-no-drain",
                message: "The soak did not end in a clean SIGTERM drain.",
                remedy: "Drive the server's SIGTERM drain at the end of the soak and record its exit status."))
        }
        let window = result.samples.filter { $0.t >= release.limits.preWarmSeconds && $0.t < release.limits.preWarmSeconds + release.limits.windowSeconds }
        if window.count >= 8, window.allSatisfy({ $0.footprintMB.isFinite && $0.footprintMB == $0.footprintMB.rounded() }) {
            findings.append(Finding(
                ruleId: "release.soak-quantised",
                message: "Every footprint reading in the judged window is a whole number of megabytes; growth under a megabyte cannot show.",
                remedy: "Sample the footprint in bytes (`footprint -f bytes`), not in whole megabytes."))
        }

        if !recomputed.notes.isEmpty {
            notes.append(Finding(
                ruleId: "release.soak-uncalibrated", message: recomputed.notes.joined(separator: "; ") + ".",
                remedy: "None required; the verdict stands, but the rule has not been measured on this host."))
        }
        return SoakReport(findings: findings, notes: notes)
    }
}
