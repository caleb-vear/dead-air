// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DeadAir",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DeadAirCore"),
        .executableTarget(name: "DeadAir", dependencies: ["DeadAirCore"]),
        .testTarget(name: "DeadAirCoreTests", dependencies: ["DeadAirCore"]),
    ]
)
