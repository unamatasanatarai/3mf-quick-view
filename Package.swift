// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "QuickLook3mf",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(
            name: "QuickLook3mf",
            targets: ["QuickLook3mf"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "QuickLook3mf",
            dependencies: [],
            path: "Sources/App"
        ),
        .testTarget(
            name: "AppTests",
            dependencies: ["QuickLook3mf"],
            path: "Tests/AppTests"
        )
    ]
)
