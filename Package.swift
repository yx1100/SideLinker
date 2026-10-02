// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SideLinker",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CGPrivate"),
        .executableTarget(name: "SideLinker", dependencies: ["CGPrivate"]),
    ]
)
