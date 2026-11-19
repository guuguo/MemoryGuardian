// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemoryGuardian",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MemoryGuardian", targets: ["MemoryGuardian"])
    ],
    targets: [
        .executableTarget(
            name: "MemoryGuardian",
            path: "Sources/MemoryGuardian",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(name: "MemoryGuardianTests", dependencies: ["MemoryGuardian"])
    ]
)
