// swift-tools-version: 5.9
// The app's Plex and file-naming code, tested on its own (swift test --package-path iOS).
import PackageDescription

let package = Package(
  name: "PlickassCore", platforms: [.macOS(.v13), .iOS(.v17)],
  targets: [
    .target(name: "PlickassCore", path: "Core"),
    .testTarget(name: "PlickassCoreTests", dependencies: ["PlickassCore"], path: "Tests"),
  ])
