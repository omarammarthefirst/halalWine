// swift-tools-version: 5.10
import PackageDescription

var products: [Product] = [
    .library(name: "HalalWineCore", targets: ["HalalWineCore"]),
    .executable(name: "halalwine", targets: ["halalwine"]),
]

var targets: [Target] = [
    // Everything that does not need a UI: inspecting games, planning launch
    // settings, managing runtimes and Wine prefixes, launching and diagnosing.
    // Builds on Linux too, so it can be unit-tested anywhere.
    .target(
        name: "HalalWineCore",
        resources: [.process("Resources")]
    ),
    // Command-line front end (power users, test harness, per-game launchers).
    .executableTarget(
        name: "halalwine",
        dependencies: ["HalalWineCore"]
    ),
    .testTarget(
        name: "HalalWineCoreTests",
        dependencies: ["HalalWineCore"]
    ),
]

#if os(macOS)
// The SwiftUI app only builds on macOS.
products.append(.executable(name: "HalalWineApp", targets: ["HalalWineApp"]))
targets.append(
    .executableTarget(
        name: "HalalWineApp",
        dependencies: ["HalalWineCore"],
        resources: [.process("Resources")]
    )
)
#endif

let package = Package(
    name: "halalWine",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
