// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ClashMenu",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "ClashMenu", targets: ["ClashMenu"]),
        .executable(name: "ClashMenuProxyHelper", targets: ["ClashMenuProxyHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.1"),
    ],
    targets: [
        .target(
            name: "ProxyHelperShared",
            path: "Sources/Helper/Shared"),
        .executableTarget(
            name: "ClashMenu",
            dependencies: [
                "ProxyHelperShared",
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/ClashBar",
            resources: [
                .copy("Resources/bin"),
                .copy("Resources/Brand/clashbar-icon.png"),
                .copy("Resources/Brand/running.png"),
                .copy("Resources/Brand/stopped.png"),
                .copy("Resources/ConfigTemplates/ClashMenu.yaml"),
                .process("Resources/Localization"),
            ]),
        .executableTarget(
            name: "ClashMenuProxyHelper",
            dependencies: ["ProxyHelperShared"],
            path: "Sources/Helper/Daemon"),
    ])
