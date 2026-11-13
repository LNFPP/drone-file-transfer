// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DroneFileTransfer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "DroneFileTransfer", path: "Sources/DroneFileTransfer")
    ]
)
