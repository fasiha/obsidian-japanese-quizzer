// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TestHarness",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "TestHarness",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/TestHarness",
        ),
    ]
)
