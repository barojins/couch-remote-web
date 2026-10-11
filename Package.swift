// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "CouchWebCore", platforms: [.macOS(.v13)], products: [.library(name: "CouchWebCore", targets: ["CouchWebCore"])], targets: [
    .target(name: "CouchWebCore", path: "Core"),
    .testTarget(name: "CouchWebCoreTests", dependencies: ["CouchWebCore"], path: "Tests", exclude: ["web.test.mjs"])
])
