// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GrandLine",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GrandLine",
            path: "Sources/GrandLine"
        )
    ]
)
