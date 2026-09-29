// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "SidecarNote",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "Vendor/KeyboardShortcuts"),  // patched: no resource bundle
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", from: "1.1.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown", from: "0.9.0"),
        .package(path: "Vendor/Highlightr"),  // patched: assets loaded from the app bundle
    ],
    targets: [
        // Reads every trackpad (built-in and Magic Trackpad) through the private MultitouchSupport framework.
        .target(name: "CMultitouch", path: "Sources/CMultitouch"),
        .executableTarget(
            name: "SidecarNote",
            dependencies: [
                "KeyboardShortcuts",
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
                .product(name: "Markdown", package: "swift-markdown"),
                "Highlightr",
                "CMultitouch",
            ],
            path: "Sources/SidecarNote",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
