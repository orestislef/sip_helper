// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "sip_helper",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "sip-helper", targets: ["sip_helper"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "sip_helper",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
