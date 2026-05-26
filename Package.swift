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
    targets: [
        .target(name: "ZMeetCore"),
        .executableTarget(
            name: "ZMeetApp",
            dependencies: ["ZMeetCore"]
        ),
        .testTarget(
            name: "ZMeetCoreTests",
            dependencies: ["ZMeetCore"]
        )
    ]
)
