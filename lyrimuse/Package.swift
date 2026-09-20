// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "lyrimuse",

    defaultLocalization: "zh-Hans",

    platforms: [.macOS(.v14)],

    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.15.0"),

    ],
    targets: [
        .target(
            name: "LyrimuseCore",
            path: "Sources/LyrimuseCore"
        ),
        .executableTarget(
            name: "lyrimuse",
            dependencies: ["LyrimuseCore", "KeyboardShortcuts"],
            path: "Sources/lyrimuse",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "lyrimuse-selftest",
            dependencies: ["LyrimuseCore"],
            path: "Sources/lyrimuse-selftest"
        ),

        .executableTarget(
            name: "lyrics-translate",
            path: "Sources/lyrics-translate"
        ),

        .executableTarget(
            name: "lyrics-romanize",
            dependencies: ["LyrimuseCore"],
            path: "Sources/lyrics-romanize"
        ),

        .executableTarget(
            name: "lyrimuse-benchmark",
            dependencies: ["LyrimuseCore"],
            path: "Sources/lyrimuse-benchmark"
        ),
    ]
)
