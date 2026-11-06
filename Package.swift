// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LarkMini",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LarkMini",
            path: "Sources/LarkMini"
        ),
        .testTarget(name: "LarkMiniTests", dependencies: ["LarkMini"])
    ]
)
