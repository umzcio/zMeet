// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "zMeet",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "zmeet", targets: ["zmeet"]),
        .library(name: "ZMeetCore", targets: ["ZMeetCore"])
    ],
    targets: [
        .target(name: "ZMeetCore"),
        .executableTarget(
            name: "zmeet",
            dependencies: ["ZMeetCore"]
        ),
        .testTarget(
            name: "ZMeetCoreTests",
            dependencies: ["ZMeetCore"]
        )
    ]
)
