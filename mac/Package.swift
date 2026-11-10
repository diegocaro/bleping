// swift-tools-version:5.9
import PackageDescription

// The Info.plist is embedded into the CLI binary so macOS can show the
// Bluetooth permission prompt for a plain command-line tool.
let infoPlist = Context.packageDirectory + "/Support/Info.plist"

let package = Package(
    name: "altiro",
    platforms: [.macOS(.v13)],
    products: [
        // Used by the menu bar app (mac/App).
        .library(name: "AltiroCore", targets: ["AltiroCore"]),
        .executable(name: "altiro", targets: ["altiro"]),
    ],
    targets: [
        // Everything except the user interface: BLE peripheral, pairing, notification
        // watching and encryption. Wire.swift is also compiled into the iPhone app.
        .target(
            name: "AltiroCore",
            path: "Sources/AltiroCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "altiro",
            dependencies: ["AltiroCore"],
            path: "Sources/altiro",
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
