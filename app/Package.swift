// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LittleCI",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "LittleCI", targets: ["LittleCIApp"]),
        .library(name: "LittleCICore", targets: ["LittleCICore"]),
    ],
    targets: [
        .target(name: "LittleCICore"),
        .executableTarget(name: "LittleCIApp", dependencies: ["LittleCICore"]),
        .testTarget(
            name: "LittleCICoreTests",
            dependencies: ["LittleCICore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
