// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChatGPTUsageWidget",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ChatGPTUsageWidget", targets: ["ChatGPTUsageWidget"]),
        .executable(name: "ChatGPTUsageWidgetParserTests", targets: ["ChatGPTUsageWidgetParserTests"]),
        .library(name: "ChatGPTUsageWidgetCore", targets: ["ChatGPTUsageWidgetCore"])
    ],
    targets: [
        .target(name: "ChatGPTUsageWidgetCore"),
        .executableTarget(
            name: "ChatGPTUsageWidget",
            dependencies: ["ChatGPTUsageWidgetCore"]
        ),
        .executableTarget(
            name: "ChatGPTUsageWidgetParserTests",
            dependencies: ["ChatGPTUsageWidgetCore"]
        )
    ]
)
