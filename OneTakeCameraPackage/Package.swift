// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OneTakeCameraPackage",
    platforms: [.iOS(.v17)],
    products: [
        .library(
            name: "CameraFeature",
            targets: ["CameraFeature"]
        ),
    ],
    dependencies: [
        .package(path: "../vendor/1Take/OneTakePackage"),
        .package(url: "https://github.com/hakaru/PeerClock.git", from: "0.2.0"),
    ],
    targets: [
        .target(
            name: "CameraFeature",
            dependencies: [
                .product(name: "OneTakeDSPCore", package: "OneTakePackage"),
                .product(name: "OneTakeDSPPresets", package: "OneTakePackage"),
                .product(name: "PeerClock", package: "PeerClock"),
            ]
        ),
    ]
)
