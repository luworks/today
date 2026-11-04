// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuietInboxCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "QuietInboxCore", targets: ["QuietInboxCore"])],
    targets: [
        .target(name: "QuietInboxCore", resources: [.process("Resources")]),
        .testTarget(name: "QuietInboxCoreTests", dependencies: ["QuietInboxCore"]),
    ]
)
