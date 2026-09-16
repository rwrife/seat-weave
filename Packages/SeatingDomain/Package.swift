// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SeatingDomain",
    platforms: [
        .iOS("26.0"),
        .macOS(.v15),
    ],
    products: [
        .library(name: "SeatingDomain", targets: ["SeatingDomain"]),
    ],
    targets: [
        .target(name: "SeatingDomain"),
        .testTarget(name: "SeatingDomainTests", dependencies: ["SeatingDomain"]),
    ]
)
