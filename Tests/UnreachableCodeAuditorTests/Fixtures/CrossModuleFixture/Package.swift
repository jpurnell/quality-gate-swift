// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrossModuleFixture",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FixtureLib", targets: ["FixtureLib"]),
        .executable(name: "FixtureExe", targets: ["FixtureExe"]),
    ],
    targets: [
        .target(name: "FixtureLib"),
        .executableTarget(name: "FixtureExe", dependencies: ["FixtureLib"]),
    ]
)
