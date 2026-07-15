// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Nearfield",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Nearfield", targets: ["Nearfield"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Nearfield",
            dependencies: [],
            exclude: [
                // Compiled separately into default.metallib by build_and_run.sh;
                // `swift build` does not handle .metal sources.
                "WaveLabEffects.metal"
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AVFAudio"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "NearfieldTests",
            dependencies: ["Nearfield"]
        )
    ]
)
