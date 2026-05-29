// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "zMeet",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "ZMeetCore", targets: ["ZMeetCore"]),
        .executable(name: "ZMeetApp", targets: ["ZMeetApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(name: "ZMeetCore"),
        .executableTarget(
            name: "ZMeetApp",
            dependencies: [
                "ZMeetCore",
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .testTarget(
            name: "ZMeetCoreTests",
            dependencies: ["ZMeetCore"]
        )
    ]
)
