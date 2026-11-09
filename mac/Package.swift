// swift-tools-version:5.9
import PackageDescription

// The Info.plist is embedded into the binary so macOS can show the
// Bluetooth permission prompt for a plain command-line tool.
let infoPlist = Context.packageDirectory + "/Support/Info.plist"

let package = Package(
    name: "bleping",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "bleping",
            path: "Sources/bleping",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlist,
                ]),
            ]
        )
    ]
)
