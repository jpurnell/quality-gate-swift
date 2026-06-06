import Foundation
import BusinessMath
import IJSSensor
import IJSAggregator
import os

extension PulseRefiner {
    /// Computes per-project trajectories using OLS regression on weighted quality scores.
    func computeTrajectories(
        projectWeightedScores: [String: Double],
        projectSnapshots: [String: [DailySnapshot]],
        projectMetadata: [String: [CheckResultMetadata]]
    ) -> [ProjectTrajectory] {
        var trajectories: [ProjectTrajectory] = []

        for (projectID, metadata) in projectMetadata {
            guard metadata.count >= 2 else {
                trajectories.append(ProjectTrajectory(
                    projectID: projectID,
                    slope: 0, intercept: 0, rSquared: 0,
                    sampleSize: metadata.count,
                    validity: .insufficient,
                    direction: .insufficient
                ))
                continue
            }

            let xValues = (0..<metadata.count).map { Double($0) }
            let yValues = metadata.map { meta -> Double in
                let checkerResults = meta.results.map { result in
                    (checkerID: result.checkerId, passed: result.status == .passed)
                }
                return SeverityWeight.weightedScore(checkerResults: checkerResults)
            }

            do {
                let slopeVal = try slope(xValues, yValues)
                let interceptVal = try intercept(xValues, yValues)
                let rSquaredVal = try rSquared(xValues, yValues)
                let sampleSize = metadata.count
                let validity = StatisticalValidity.from(sampleSize: sampleSize)
                let direction = TrajectoryDirection.from(slope: slopeVal, sampleSize: sampleSize)

                var inflection = false
                var recentSlopeVal: Double?
                if sampleSize >= 6 {
                    let halfPoint = sampleSize / 2
                    let recentX = Array(xValues[halfPoint...])
                    let recentY = Array(yValues[halfPoint...])
                    do {
                        let rs = try slope(recentX, recentY)
                        recentSlopeVal = rs
                        let fullDirection = slopeVal > 0
                        let recentDirection = rs > 0
                        if fullDirection != recentDirection && abs(rs) > 0.005 {
                            inflection = true
                        }
                    } catch {
                        Self.logger.warning("Inflection detection failed for \(projectID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }

                trajectories.append(ProjectTrajectory(
                    projectID: projectID,
                    slope: slopeVal,
                    intercept: interceptVal,
                    rSquared: rSquaredVal,
                    sampleSize: sampleSize,
                    validity: validity,
                    direction: direction,
                    inflectionDetected: inflection,
                    recentSlope: recentSlopeVal
                ))
            } catch {
                trajectories.append(ProjectTrajectory(
                    projectID: projectID,
                    slope: 0, intercept: 0, rSquared: 0,
                    sampleSize: metadata.count,
                    validity: .insufficient,
                    direction: .insufficient
                ))
            }
        }

        return trajectories.sorted { $0.projectID < $1.projectID }
    }
}
