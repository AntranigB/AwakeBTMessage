// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AwakeCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AwakeCore", targets: ["AwakeCore"])
    ],
    targets: [
        .target(name: "AwakeCore", path: "Sources/AwakeCore"),
        .testTarget(name: "AwakeCoreTests",
                    dependencies: ["AwakeCore"],
                    path: "Tests/AwakeCoreTests")
    ]
)
