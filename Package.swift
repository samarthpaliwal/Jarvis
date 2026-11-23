// swift-tools-version:5.10
import PackageDescription

// Jarvis is split in two targets:
//  - JarvisCore: all app logic (testable library)
//  - Jarvis:     a thin executable that boots NSApplication
//  - JarvisObjC: a tiny Objective-C shim for catching NSException
//  - JarvisKeyHelper: a small frozen helper that holds saved keys behind Touch ID
let package = Package(
    name: "Jarvis",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Jarvis", targets: ["Jarvis"]),
        .executable(name: "jarvis-keyhelper", targets: ["JarvisKeyHelper"]),
        .library(name: "JarvisCore", targets: ["JarvisCore"]),
    ],
    dependencies: [
        // On-device inference for the openWakeWord "hey jarvis" models.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.20.0"),
    ],
    targets: [
        // Objective-C shim: turns NSException into a Swift error (AVAudioEngine raises them).
        .target(name: "JarvisObjC", path: "Sources/JarvisObjC"),
        .target(
            name: "JarvisCore",
            dependencies: [
                "JarvisObjC",
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
        // Keeps saved keys and releases them after Touch ID. Built once, then left alone (see main.swift).
        .executableTarget(name: "JarvisKeyHelper", path: "Sources/JarvisKeyHelper"),
        .testTarget(
            name: "JarvisCoreTests",
            dependencies: ["JarvisCore"],
            path: "Tests/JarvisCoreTests",
            exclude: ["Fixtures"]      // read from disk by path; not bundled
        ),
    ]
)
