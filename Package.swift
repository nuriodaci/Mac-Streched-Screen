// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Mac-Streched-Screen",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Mac-Streched-Screen", targets: ["MacStrechedScreen"]),
        .executable(name: "PreviewRenderer", targets: ["PreviewRenderer"]),
        .executable(name: "StretchRestoreHelper", targets: ["StretchRestoreHelper"]),
        .library(name: "StretchCore", targets: ["StretchCore"]),
    ],
    targets: [
        .target(name: "StretchCore"),
        .target(name: "AppUI", dependencies: ["StretchCore"]),
        .executableTarget(
            name: "MacStrechedScreen",
            dependencies: ["StretchCore", "AppUI"]
        ),
        .executableTarget(
            name: "PreviewRenderer",
            dependencies: ["StretchCore", "AppUI"]
        ),
        .executableTarget(
            name: "StretchRestoreHelper",
            dependencies: ["StretchCore"]
        ),
        .testTarget(name: "AppUITests", dependencies: ["AppUI", "StretchCore"]),
        .testTarget(
            name: "StretchCoreTests",
            dependencies: ["StretchCore"]
        ),
    ]
)
