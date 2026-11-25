// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "APIPlayground",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "APIEngine", targets: ["APIEngine"]),
        .executable(name: "APIPlayground", targets: ["APIPlayground"]),
    ],
    targets: [
        // Thin C wrappers around libcurl's variadic functions, which Swift cannot call.
        .target(
            name: "CCurlShim",
            linkerSettings: [.linkedLibrary("curl")]
        ),
        // Model, storage, variables, importers and HTTP. No UI dependencies.
        .target(
            name: "APIEngine",
            dependencies: ["CCurlShim"]
        ),
        .executableTarget(
            name: "APIPlayground",
            dependencies: ["APIEngine"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "APIEngineTests",
            dependencies: ["APIEngine"]
        ),
    ]
)
