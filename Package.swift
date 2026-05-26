// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "zMeet",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "ZMeetCore", targets: ["ZMeetCore"])
    ],
    targets: [
        .target(name: "ZMeetCore"),
        .testTarget(
            name: "ZMeetCoreTests",
            dependencies: ["ZMeetCore"]
        )
    ]
)
