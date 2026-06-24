// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FeatherMac",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "FeatherMac", targets: ["FeatherMac"]),
        .executable(name: "FeatherMacSelfTest", targets: ["FeatherMacSelfTest"]),
        .executable(name: "FeatherMacSignInstallTest", targets: ["FeatherMacSignInstallTest"])
    ],
    dependencies: [
        .package(path: "Vendor/AltSourceKit"),
        .package(path: "Vendor/Zsign")
    ],
    targets: [
        .executableTarget(
            name: "FeatherMac",
			dependencies: [
				"AltSourceKit",
				.product(name: "ZsignSwift", package: "Zsign")
			],
			resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "FeatherMacSelfTest",
            dependencies: [
                "AltSourceKit"
            ],
            path: "Sources/FeatherMacSelfTest"
        ),
        .executableTarget(
            name: "FeatherMacSignInstallTest",
            dependencies: [
                .product(name: "ZsignSwift", package: "Zsign")
            ],
            path: "Sources/FeatherMacSignInstallTest"
        )
    ]
)
