// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mosaic",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Mosaic", targets: ["Mosaic"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "MosaicCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "Mosaic", dependencies: ["MosaicCore"]),
        .testTarget(name: "MosaicCoreTests", dependencies: ["MosaicCore", "CSQLite"]),
        .testTarget(name: "MosaicUITests", dependencies: ["Mosaic", "MosaicCore", "CSQLite"])
    ],
    swiftLanguageModes: [.v5]
)
