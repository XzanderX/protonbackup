// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Neutrony",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Neutrony", targets: ["Neutrony"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Neutrony",
            dependencies: [],
            path: "Neutrony",
            exclude: [
                "Info.plist",
                "Neutrony.entitlements"
            ],
            resources: [
                .process("Assets.xcassets")
            ]
        ),
        .testTarget(
            name: "NeutronyTests",
            dependencies: ["Neutrony"],
            path: "Tests/NeutronyTests"
        )
    ]
)
