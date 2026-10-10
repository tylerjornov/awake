// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Awake",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Awake", targets: ["AwakeApp"]),
        .executable(name: "awake", targets: ["AwakeCLI"]),
    ],
    targets: [
        .target(name: "AwakeCore"),
        .target(
            name: "AwakeMac",
            dependencies: ["AwakeCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .executableTarget(name: "AwakeApp", dependencies: ["AwakeMac"]),
        .executableTarget(name: "AwakeCLI", dependencies: ["AwakeMac"]),
        .testTarget(name: "AwakeCoreTests", dependencies: ["AwakeCore"]),
    ]
)
