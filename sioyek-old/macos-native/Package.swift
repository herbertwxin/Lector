// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Sioyek",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Sioyek",
            path: "Sources/Sioyek",
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
