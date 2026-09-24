// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TranscriberCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TranscriberCore", targets: ["TranscriberCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.4.0"),
    ],
    targets: [
        .target(
            name: "EchoCancel",
            path: "Sources/EchoCancel",
            publicHeadersPath: "include"
        ),
        .target(
            name: "TranscriberCore",
            dependencies: [
                "EchoCancel",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "TranscriberCoreTests",
            dependencies: [
                "TranscriberCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
