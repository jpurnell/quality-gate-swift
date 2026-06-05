import Testing
import Foundation
@testable import IJSSensor

@Suite("TrajectoryDirection")
struct TrajectoryDirectionTests {

    // MARK: - Raw Values

    @Test("Raw string values match case names")
    func rawValues() {
        #expect(TrajectoryDirection.improving.rawValue == "improving")
        #expect(TrajectoryDirection.stable.rawValue == "stable")
        #expect(TrajectoryDirection.declining.rawValue == "declining")
        #expect(TrajectoryDirection.insufficient.rawValue == "insufficient")
    }

    // MARK: - from(slope:sampleSize:)

    @Test("Insufficient data when sample size < 3")
    func insufficientData() {
        #expect(TrajectoryDirection.from(slope: 0.5, sampleSize: 0) == .insufficient)
        #expect(TrajectoryDirection.from(slope: 0.5, sampleSize: 1) == .insufficient)
        #expect(TrajectoryDirection.from(slope: 0.5, sampleSize: 2) == .insufficient)
    }

    @Test("Positive slope classifies as improving")
    func improving() {
        #expect(TrajectoryDirection.from(slope: 0.01, sampleSize: 10) == .improving)
    }

    @Test("Negative slope classifies as declining")
    func declining() {
        #expect(TrajectoryDirection.from(slope: -0.01, sampleSize: 10) == .declining)
    }

    @Test("Near-zero positive slope classifies as stable")
    func stablePositive() {
        #expect(TrajectoryDirection.from(slope: 0.004, sampleSize: 10) == .stable)
    }

    @Test("Near-zero negative slope classifies as stable")
    func stableNegative() {
        #expect(TrajectoryDirection.from(slope: -0.004, sampleSize: 10) == .stable)
    }

    @Test("Boundary: slope exactly 0.005 classifies as improving")
    func boundaryPositive() {
        #expect(TrajectoryDirection.from(slope: 0.005, sampleSize: 10) == .improving)
    }

    @Test("Boundary: slope exactly -0.005 classifies as declining")
    func boundaryNegative() {
        #expect(TrajectoryDirection.from(slope: -0.005, sampleSize: 10) == .declining)
    }

    // MARK: - Codable Round-Trip

    @Test("Codable round-trip for each case")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let allCases: [TrajectoryDirection] = [.improving, .stable, .declining, .insufficient]
        for direction in allCases {
            let data = try encoder.encode(direction)
            let decoded = try decoder.decode(TrajectoryDirection.self, from: data)
            #expect(decoded == direction)
        }
    }

    @Test("Encodes as quoted string")
    func encodesAsString() throws {
        let data = try JSONEncoder().encode(TrajectoryDirection.improving)
        let jsonString = String(data: data, encoding: .utf8)
        #expect(jsonString == "\"improving\"")
    }
}

@Suite("ProjectTrajectory")
struct ProjectTrajectoryTests {

    // MARK: - Initialization

    @Test("Init with all parameters")
    func initAllParameters() {
        let trajectory = ProjectTrajectory(
            projectID: "proj-1",
            slope: 0.02,
            intercept: 0.5,
            rSquared: 0.85,
            sampleSize: 30,
            validity: .valid,
            direction: .improving,
            inflectionDetected: true,
            recentSlope: 0.03
        )

        #expect(trajectory.projectID == "proj-1")
        #expect(trajectory.slope == 0.02)
        #expect(trajectory.intercept == 0.5)
        #expect(trajectory.rSquared == 0.85)
        #expect(trajectory.sampleSize == 30)
        #expect(trajectory.validity == .valid)
        #expect(trajectory.direction == .improving)
        #expect(trajectory.inflectionDetected == true)
        #expect(trajectory.recentSlope == 0.03)
    }

    @Test("Init defaults: inflectionDetected=false, recentSlope=nil")
    func initDefaults() {
        let trajectory = ProjectTrajectory(
            projectID: "proj-2",
            slope: -0.01,
            intercept: 0.8,
            rSquared: 0.6,
            sampleSize: 15,
            validity: .preliminary,
            direction: .declining
        )

        #expect(trajectory.inflectionDetected == false)
        #expect(trajectory.recentSlope == nil)
    }

    // MARK: - Codable Round-Trip

    @Test("Codable round-trip with all fields populated")
    func codableRoundTripFull() throws {
        let trajectory = ProjectTrajectory(
            projectID: "proj-1",
            slope: 0.02,
            intercept: 0.5,
            rSquared: 0.85,
            sampleSize: 30,
            validity: .valid,
            direction: .improving,
            inflectionDetected: true,
            recentSlope: 0.03
        )

        let data = try JSONEncoder().encode(trajectory)
        let decoded = try JSONDecoder().decode(ProjectTrajectory.self, from: data)
        #expect(decoded == trajectory)
    }

    @Test("Codable round-trip with optional fields nil")
    func codableRoundTripNil() throws {
        let trajectory = ProjectTrajectory(
            projectID: "proj-2",
            slope: -0.01,
            intercept: 0.8,
            rSquared: 0.6,
            sampleSize: 15,
            validity: .preliminary,
            direction: .declining
        )

        let data = try JSONEncoder().encode(trajectory)
        let decoded = try JSONDecoder().decode(ProjectTrajectory.self, from: data)
        #expect(decoded == trajectory)
    }

    // MARK: - Equatable

    @Test("Equal trajectories compare as equal")
    func equatable() {
        let a = ProjectTrajectory(
            projectID: "proj-1",
            slope: 0.02,
            intercept: 0.5,
            rSquared: 0.85,
            sampleSize: 30,
            validity: .valid,
            direction: .improving
        )
        let b = ProjectTrajectory(
            projectID: "proj-1",
            slope: 0.02,
            intercept: 0.5,
            rSquared: 0.85,
            sampleSize: 30,
            validity: .valid,
            direction: .improving
        )
        #expect(a == b)
    }

    @Test("Different trajectories compare as not equal")
    func notEquatable() {
        let a = ProjectTrajectory(
            projectID: "proj-1",
            slope: 0.02,
            intercept: 0.5,
            rSquared: 0.85,
            sampleSize: 30,
            validity: .valid,
            direction: .improving
        )
        let b = ProjectTrajectory(
            projectID: "proj-2",
            slope: 0.02,
            intercept: 0.5,
            rSquared: 0.85,
            sampleSize: 30,
            validity: .valid,
            direction: .improving
        )
        #expect(a != b)
    }

    // MARK: - Validity Consistency

    @Test("Validity field matches StatisticalValidity.from(sampleSize:)")
    func validityMatchesSampleSize() {
        let trajectory = ProjectTrajectory(
            projectID: "proj-1",
            slope: 0.02,
            intercept: 0.5,
            rSquared: 0.85,
            sampleSize: 30,
            validity: StatisticalValidity.from(sampleSize: 30),
            direction: .improving
        )
        #expect(trajectory.validity == .valid)

        let preliminary = ProjectTrajectory(
            projectID: "proj-2",
            slope: 0.01,
            intercept: 0.3,
            rSquared: 0.5,
            sampleSize: 10,
            validity: StatisticalValidity.from(sampleSize: 10),
            direction: .improving
        )
        #expect(preliminary.validity == .preliminary)

        let insufficient = ProjectTrajectory(
            projectID: "proj-3",
            slope: 0.0,
            intercept: 0.0,
            rSquared: 0.0,
            sampleSize: 2,
            validity: StatisticalValidity.from(sampleSize: 2),
            direction: .insufficient
        )
        #expect(insufficient.validity == .insufficient)
    }
}
