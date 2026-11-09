// swift-tools-version:5.9
import PackageDescription

// The Info.plist is embedded into the CLI binary so macOS can show the
// Bluetooth permission prompt for a plain command-line tool.
let infoPlist = Context.packageDirectory + "/Support/Info.plist"

let package = Package(
    name: "bleping",
    platforms: [.macOS(.v13)],
    products: [
        // Used by the menu bar app (mac/App).
        .library(name: "BlePingCore", targets: ["BlePingCore"]),
        .executable(name: "bleping", targets: ["bleping"]),
    ],
    targets: [
        // Everything except the user interface: BLE peripheral, pairing, notification
        // watching and encryption. Wire.swift is also compiled into the iPhone app.
        .target(
            name: "BlePingCore",
            path: "Sources/BlePingCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "bleping",
            dependencies: ["BlePingCore"],
            path: "Sources/bleping",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlist,
                ]),
            ]
        ),
    ]
)
