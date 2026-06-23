// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "RoonLogWatcher",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "RoonLogWatcherCore", targets: ["RoonLogWatcherCore"]),
        .executable(name: "RoonLogWatcher", targets: ["RoonLogWatcher"])
    ],
    targets: [
        .target(name: "RoonLogWatcherCore"),
        .executableTarget(
            name: "RoonLogWatcher",
            dependencies: ["RoonLogWatcherCore"]
        ),
        .testTarget(
            name: "RoonLogWatcherTests",
            dependencies: ["RoonLogWatcherCore"]
        )
    ]
)
