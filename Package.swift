// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LlamaEngine",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        // Core: backends, context/RAG, services, settings. No SwiftUI / SwiftData.
        .library(name: "LlamaEngine", targets: ["LlamaEngine"]),
        // Batteries-included SwiftData store + the persisting conversation controller.
        .library(name: "LlamaEngineStore", targets: ["LlamaEngineStore"]),
    ],
    targets: [
        .target(name: "LlamaEngine"),
        .target(
            name: "LlamaEngineStore",
            dependencies: ["LlamaEngine"]
        ),
        .testTarget(
            name: "LlamaEngineTests",
            dependencies: ["LlamaEngine"]
        ),
        .testTarget(
            name: "LlamaEngineStoreTests",
            dependencies: ["LlamaEngineStore", "LlamaEngine"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
