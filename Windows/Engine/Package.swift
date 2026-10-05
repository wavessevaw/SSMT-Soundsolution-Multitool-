// swift-tools-version:5.9
import PackageDescription

// The Windows app's engine: the same SSMTCore as the macOS app, driven over stdin / stdout (JSON lines) by the
// Electron interface in Windows/App. It never opens a socket itself: the interface carries the UDP packets.
let package = Package(
    name: "SSMTEngine",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../../Packages/SSMTCore")],
    targets: [
        .executableTarget(name: "ssmt-engine", dependencies: [.product(name: "SSMTCore", package: "SSMTCore")]),
    ]
)
