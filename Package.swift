// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "APIPlayground",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "APIEngine", targets: ["APIEngine"]),
        .executable(name: "APIPlayground", targets: ["APIPlayground"]),
    ],
    dependencies: [
        // In-app updates for the direct download.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
        // libgit2, built from source, so Git Sync does not need Git installed on the Mac.
        // Pinned to the commit tagged v1.9.7: its build flags are only allowed for an exact commit.
        .package(url: "https://github.com/Formkunft/swift-libgit2.git", revision: "e7605bb30202a6f4c509dc4cc538953d66162e6a"),
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
            dependencies: ["CCurlShim", .product(name: "Clibgit2", package: "swift-libgit2")],
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(
            name: "APIPlayground",
            dependencies: ["APIEngine", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "APIEngineTests",
            dependencies: ["APIEngine"]
        ),
    ]
)
