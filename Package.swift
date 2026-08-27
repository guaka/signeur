// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "signstr",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "SignstrCore", targets: ["SignstrCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/21-dot-dev/swift-secp256k1.git", from: "0.21.0")
    ],
    targets: [
        .target(
            name: "SignstrCore",
            dependencies: [
                .product(name: "P256K", package: "swift-secp256k1")
            ],
            path: ".",
            exclude: [
                "Tests",
                "plan.md",
                "iOSApp",
                "MacOSApp",
                "Distribution",
                "Scripts",
                "Tools",
                "README.md",
                "project.yml"
            ],
            sources: [
                "App",
                "Data",
                "Domain",
                "Wallet",
                "NIP46",
                "Nostr",
                "Shared"
            ]
        ),
        .testTarget(
            name: "SignstrCoreTests",
            dependencies: ["SignstrCore"],
            path: "Tests",
            resources: [
                .copy("Vectors/nip44.vectors.json")
            ]
        )
    ]
)
