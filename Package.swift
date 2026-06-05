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
        .target(
            name: "CSpeexDSP",
            path: "Sources/CSpeexDSP",
            cSettings: [
                .headerSearchPath("include"),
                .define("HAVE_CONFIG_H"),
                .define("OUTSIDE_SPEEX"),
                .define("FLOATING_POINT"),
                .define("USE_KISS_FFT")
            ]
        ),
        .target(
            name: "ZMeetCore",
            dependencies: ["CSpeexDSP"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
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
