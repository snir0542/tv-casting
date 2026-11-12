// swift-tools-version:5.9
// Platform-independent parts of the broadcast extension, unit-tested in CI with `swift test`.
// The extension target compiles the same files (see project.yml).
import PackageDescription

let package = Package(
    name: "MirrorCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    targets: [
        .target(name: "MirrorCore", path: "Core"),
        .testTarget(name: "MirrorCoreTests", dependencies: ["MirrorCore"], path: "Tests/MirrorCoreTests"),
    ]
)
