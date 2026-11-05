// swift-tools-version:5.10
import PackageDescription

// Jarvis is split in two targets:
//  - JarvisCore: all app logic (testable library)
//  - Jarvis:     a thin executable that boots NSApplication
let package = Package(
    name: "Jarvis",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Jarvis", targets: ["Jarvis"]),
        .library(name: "JarvisCore", targets: ["JarvisCore"]),
    ],
    dependencies: [
        // On-device inference for the openWakeWord "hey jarvis" models.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.20.0"),
    ],
    targets: [
        .target(
            name: "JarvisCore",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/JarvisCore",
            resources: [.copy("Resources/Models")]
        ),
        .executableTarget(
            name: "Jarvis",
            dependencies: ["JarvisCore"],
            path: "Sources/Jarvis"
        ),
        .testTarget(
            name: "JarvisCoreTests",
            dependencies: ["JarvisCore"],
            path: "Tests/JarvisCoreTests"
        ),
    ]
)
