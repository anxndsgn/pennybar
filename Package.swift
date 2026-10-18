// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PennyBar",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "PennyBar", targets: ["PennyBar"]),
    ],
    targets: [
        .target(name: "PennyBarCore"),
        .executableTarget(name: "PennyBar", dependencies: ["PennyBarCore"]),
        .testTarget(name: "PennyBarCoreTests", dependencies: ["PennyBarCore"]),
    ]
)
