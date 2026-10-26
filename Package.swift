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
        .target(name: "ProcessIdentityCore", path: "Sources/ProcessIdentityCore"),
        .executableTarget(
            name: "ApexSignal",
            dependencies: ["ProcessIdentityCore"],
            path: "Sources/ApexSignal"
        ),
        .executableTarget(
            name: "ApexFanHelper",
            dependencies: ["FanControlCore"],
            path: "Sources/ApexFanHelper",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "TaskManager",
            dependencies: ["FanControlCore", "DetectionCore", "ProcessIdentityCore"],
            path: "Sources/TaskManager",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("IOUSBHost"),
                .linkedFramework("CoreWLAN"),
            ]
        ),
        .testTarget(
            name: "TaskManagerTests",
            dependencies: ["TaskManager", "FanControlCore", "DetectionCore", "ProcessIdentityCore", "ApexSignal"],
            path: "Tests/TaskManagerTests",
            exclude: ["Fixtures"]      // read from the source folder (#filePath), not bundled
        ),
    ]
)
