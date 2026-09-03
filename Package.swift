// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "rec",
    platforms: [
        // captureMicrophone needs macOS 15; SCContentFilter.includedWindows
        // (used to label picker selections) needs 15.2.
        .macOS("15.2")
    ],
    targets: [
        // Capture engine + shared helpers, used by both the CLI and RecBar.
        .target(name: "RecCore", path: "Sources/RecCore"),

        .executableTarget(
            name: "rec",
            dependencies: ["RecCore"],
            path: "Sources/rec",
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed an Info.plist into the bare executable so TCC has a
                // bundle id + mic usage description to attach permissions to.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/rec/Info.plist",
                ])
            ]
        ),

        // Menu bar app; `make app` wraps this binary into RecBar.app.
        .executableTarget(
            name: "RecBar",
            dependencies: ["RecCore"],
            path: "Sources/RecBar",
            exclude: ["Info.plist"]
        ),
    ]
)
