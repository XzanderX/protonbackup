// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ProtonBackup",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ProtonBackup", targets: ["ProtonBackup"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "ProtonBackup",
            dependencies: [],
            path: "ProtonBackup",
            exclude: [
                "Info.plist",
                "ProtonBackup.entitlements"
            ],
            resources: [
                .process("Assets.xcassets")
            ]
        ),
        .testTarget(
            name: "ProtonBackupTests",
            dependencies: ["ProtonBackup"],
            path: "Tests/ProtonBackupTests"
        )
    ]
)
