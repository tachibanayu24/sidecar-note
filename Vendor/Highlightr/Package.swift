// swift-tools-version:5.3
// Vendored from https://github.com/raspu/Highlightr (MIT) — patched for Sidecar Note:
// resources are not declared here; scripts/build-app.sh copies them into the app as
// Contents/Resources/Highlightr.bundle, and Highlightr.swift loads them from there.

import PackageDescription

let package = Package(
    name: "Highlightr",
    platforms: [.macOS(.v10_11)],
    products: [.library(name: "Highlightr", targets: ["Highlightr"])],
    targets: [
        .target(name: "Highlightr", path: "src", exclude: ["assets"], sources: ["classes"]),
    ]
)
