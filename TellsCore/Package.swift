// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TellsCore",
    platforms: [.macOS(.v26), .iOS(.v26)], // DEFAULT: D-003
    products: [
        .library(name: "TellsCore", targets: ["TellsCore"]),
    ],
    targets: [
        .target(name: "TellsCore"),
        .testTarget(name: "TellsCoreTests", dependencies: ["TellsCore"]), // DEFAULT: D-004
    ],
    swiftLanguageModes: [.v6]
)
