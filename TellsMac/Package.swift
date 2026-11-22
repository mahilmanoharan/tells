// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TellsMac",
    platforms: [.macOS(.v26)], // DEFAULT: D-003
    products: [
        .library(name: "MacSensors", targets: ["MacSensors"]),
        .library(name: "CompanionUI", targets: ["CompanionUI"]),
    ],
    dependencies: [
        .package(path: "../TellsCore"),
    ],
    targets: [
        .target(name: "MacSensors", dependencies: ["TellsCore"]),
        .target(name: "CompanionUI", dependencies: ["TellsCore"]),
    ],
    swiftLanguageModes: [.v6]
)
