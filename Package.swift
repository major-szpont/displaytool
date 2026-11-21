// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DisplayTool",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DisplayTool",
            path: "Sources/DisplayTool",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
    ]
)
