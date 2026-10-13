// swift-tools-version:5.7
// Package.swift ở gốc repo để cài iOS SDK qua Swift Package Manager bằng URL repo:
// Xcode → File → Add Package Dependencies… → https://github.com/DaoChiMinh/tingpush-sdk
import PackageDescription

let package = Package(
    name: "TingPush",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "TingPush", targets: ["TingPush"])
    ],
    targets: [
        .target(name: "TingPush", path: "ios/Sources/TingPush")
    ]
)
