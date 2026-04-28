// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FSRS",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(
            name: "FSRS",
            targets: ["FSRS"]),
    ],
    targets: [
        .target(
            name: "FSRS",
            path: "Sources/FSRS/"
        ),
        .testTarget(
            name: "FSRSTests",
            dependencies: ["FSRS"],
            path: "./Tests/FSRSTests"
        ),
    ]
)
