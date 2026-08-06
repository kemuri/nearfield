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
                "WaveLabEffects.metal",
                // Distribution resources are copied explicitly by
                // build_app_bundle.sh. Avoid SwiftPM's generated Bundle.module
                // accessor because it embeds a fatal source-tree fallback.
                "Resources"
            ],
            swiftSettings: [
                .define("NEARFIELD_DISTRIBUTION", .when(configuration: .release)),
                // SwiftPM otherwise adds the active Xcode toolchain as an
                // absolute runtime search path to the executable.
                .unsafeFlags(["-no-toolchain-stdlib-rpath"])
            ],
            linkerSettings: [
                .linkedFramework("AVFAudio"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "NearfieldTests",
            dependencies: ["Nearfield"],
            swiftSettings: [
                // Keep the test module in the same feature configuration as
                // the executable it imports.
                .define("NEARFIELD_DISTRIBUTION", .when(configuration: .release))
            ]
        )
    ]
)
