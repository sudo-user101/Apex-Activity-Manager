// swift-tools-version: 5.10
// Apex Activity Manager by CyberNet Labs: a native macOS activity manager.
// Build the .app with ./build.sh (wraps `swift build -c release`).
import PackageDescription

let package = Package(
    name: "TaskManager",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "FanControlCore", path: "Sources/FanControlCore"),
        .target(name: "DetectionCore", path: "Sources/DetectionCore"),
        .executableTarget(
            name: "ApexFanHelper",
            dependencies: ["FanControlCore"],
            path: "Sources/ApexFanHelper",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "TaskManager",
            dependencies: ["FanControlCore", "DetectionCore"],
            path: "Sources/TaskManager",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("DiskArbitration"),
            ]
        ),
        .testTarget(
            name: "TaskManagerTests",
            dependencies: ["TaskManager", "FanControlCore", "DetectionCore"],
            path: "Tests/TaskManagerTests"
        ),
    ]
)
