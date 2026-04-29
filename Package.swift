// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XCodeMCPService",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "MCPServiceCore", targets: ["MCPServiceCore"]),
        .executable(name: "XCodeMCPService", targets: ["XCodeMCPService"]),
        .executable(name: "XCodeMCPStatusBar", targets: ["XCodeMCPStatusBar"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.12.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.9.0")
    ],
    targets: [
        .target(
            name: "MCPServiceCore",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .executableTarget(
            name: "XCodeMCPService",
            dependencies: [
                "MCPServiceCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "XCodeMCPStatusBar",
            dependencies: [
                "MCPServiceCore"
            ],
            exclude: ["Info.plist", "AppIcon.icns"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "MCPServiceCoreTests",
            dependencies: [
                "MCPServiceCore"
            ]
        )
    ]
)
