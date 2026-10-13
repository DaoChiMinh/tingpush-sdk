// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "tingpush",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "tingpush", targets: ["tingpush"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        // Plugin Flutter khác: Flutter tự đổi "../flutter_callkit_incoming" thành đường dẫn đúng khi build.
        .package(name: "flutter_callkit_incoming", path: "../flutter_callkit_incoming")
    ],
    targets: [
        .target(
            name: "tingpush",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "flutter-callkit-incoming", package: "flutter_callkit_incoming")
            ]
        )
    ]
)
