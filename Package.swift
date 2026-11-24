// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TheDragon",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TheDragon", targets: ["TheDragon"]),
    ],
    targets: [
        .target(
            name: "CZlib",
            path: "Sources/CZlib",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "DragonCurve",
            dependencies: ["CZlib"],
            path: "Sources/DragonCurve"
        ),
        .target(
            name: "Dragonscale",
            path: "Sources/Dragonscale",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "Dragonfold",
            path: "Sources/Dragonfold"
        ),
        .target(
            name: "Dragonreel",
            path: "Sources/Dragonreel",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]
        ),
        .executableTarget(
            name: "TheDragon",
            dependencies: ["DragonCurve", "Dragonscale", "Dragonfold", "Dragonreel"],
            path: "Sources/TheDragon"
        ),
    ]
)
