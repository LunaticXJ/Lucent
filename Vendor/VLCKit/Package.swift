// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VLCKit",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14)],
    products: [.library(name: "VLCKit", targets: ["VLCKit"])],
    targets: [.binaryTarget(name: "VLCKit", path: "VLCKit.xcframework")]
)
