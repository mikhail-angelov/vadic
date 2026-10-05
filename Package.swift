// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vadic",
    platforms: [.macOS("14.2")],
    targets: [
        .target(name: "VadicCore"),
        .executableTarget(name: "Vadic", dependencies: ["VadicCore"]),
        .testTarget(
            name: "VadicCoreTests",
            dependencies: ["VadicCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
