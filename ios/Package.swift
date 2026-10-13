// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "TingPush",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "TingPush", targets: ["TingPush"])
    ],
    targets: [
        .target(name: "TingPush", path: "Sources/TingPush")
    ]
)
