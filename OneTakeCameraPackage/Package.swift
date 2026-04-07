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
        .package(path: "../../1Take/OneTakePackage"),
    ],
    targets: [
        .target(
            name: "CameraFeature",
            dependencies: [
                .product(name: "OneTakeDSPCore", package: "OneTakePackage"),
                .product(name: "OneTakeDSPPresets", package: "OneTakePackage"),
            ]
        ),
    ]
)
