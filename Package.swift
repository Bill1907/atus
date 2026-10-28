// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Atus",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Atus", targets: ["Atus"]),
    ],
    targets: [
        .target(name: "AtusCore"),
        .executableTarget(name: "Atus", dependencies: ["AtusCore"]),
        .testTarget(name: "AtusCoreTests", dependencies: ["AtusCore"]),
    ]
)
