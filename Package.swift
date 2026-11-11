// swift-tools-version: 5.10
import Foundation
import PackageDescription

let cliPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/CLI-Info.plist")

let package = Package(
    name: "ReMeet",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "ReMeet", targets: ["MeetingNotes"]),
        .executable(name: "remeet", targets: ["MeetingNotesCLI"]),
    ],
    targets: [
        .target(name: "MeetingCore"),
        .executableTarget(name: "MeetingNotes", dependencies: ["MeetingCore"]),
        .executableTarget(
            name: "MeetingNotesCLI",
            dependencies: ["MeetingCore"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist", "-Xlinker", cliPlist.path,
            ])]
        ),
    ]
)
