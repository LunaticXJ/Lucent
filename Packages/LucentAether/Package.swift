// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "LucentAether",
    platforms: [.iOS(.v18), .tvOS(.v18), .macOS(.v15)],
    // Keep Aether's FFmpeg references in a separate Mach-O image. A static
    // product lets MPVKit's static FFmpeg satisfy these symbols in the app,
    // even though the two engines were built against different FFmpeg ABIs.
    products: [.library(name: "LucentAether", type: .dynamic, targets: ["LucentAether"])],
    dependencies: [
        .package(
            url: "https://github.com/superuser404notfound/AetherEngine.git",
            revision: "61250c9f9fe1624d4ac4b2d069fb0bdaca2cc213",
            traits: ["TrueHDObjectAudio", "DTSXObjectAudio", "DualLayerDolbyVision"]
        )
    ],
    targets: [
        .target(name: "LucentAether", dependencies: [
            .product(name: "AetherEngine", package: "AetherEngine")
        ])
    ]
)
