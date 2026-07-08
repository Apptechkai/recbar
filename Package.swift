// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "rec",
    platforms: [
        // captureMicrophone on SCStreamConfiguration needs macOS 15+
        .macOS("15.0")
    ],
    targets: [
        .executableTarget(
            name: "rec",
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
        )
    ]
)
