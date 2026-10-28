// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "tabdisplay",
    platforms: [.macOS(.v14)],
    targets: [
        // Header-only bridge to Apple's private CGVirtualDisplay classes (live in CoreGraphics).
        .target(name: "CGVirtualDisplayPrivate"),
        .executableTarget(
            name: "tabdisplay",
            dependencies: ["CGVirtualDisplayPrivate"],
            resources: [.copy("Resources/index.html")]
        ),
    ]
)
