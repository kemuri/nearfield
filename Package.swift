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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "Nearfield",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            exclude: [
                // Compiled separately into default.metallib by build_and_run.sh;
                // `swift build` does not handle .metal sources.
                "WaveLabEffects.metal"
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .define("NEARFIELD_DISTRIBUTION", .when(configuration: .release))
            ],
            linkerSettings: [
                .linkedFramework("AVFAudio"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "NearfieldTests",
            dependencies: ["Nearfield"]
        )
    ]
)
