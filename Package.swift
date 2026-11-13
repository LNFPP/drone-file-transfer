// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LotShotsSorter",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "LotShotsSorter", path: "Sources/LotShotsSorter")
    ]
)
