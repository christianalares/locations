// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocationsKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "LocationsKit", targets: ["LocationsKit"])],
    targets: [
        .target(
            name: "LocationsKit",
            resources: [.process("Resources")]
        ),
        .testTarget(name: "LocationsKitTests", dependencies: ["LocationsKit"])
    ]
)
