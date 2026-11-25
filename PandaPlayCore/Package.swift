// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PandaPlayCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PandaPlayCore", targets: ["PandaPlayCore"])
    ],
    targets: [
        .target(
            name: "PandaPlayCore",
            path: "Sources/PandaPlayCore"
        ),
        .testTarget(
            name: "PandaPlayCoreTests",
            dependencies: ["PandaPlayCore"],
            path: "Tests/PandaPlayCoreTests"
        ),
    ]
)
