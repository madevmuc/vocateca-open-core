// swift-tools-version: 6.0
import PackageDescription

// Vocateca — open core.
//
// This package is the OPEN-SOURCE core of Vocateca (https://vocateca.com):
// the local-first transcription engine, its domain/state layer, and the
// `vocateca-cli` command-line tool (which also speaks the Model Context
// Protocol via `vocateca-cli mcp`).
//
// Products:
//   • VocatecaCore      — domain logic, state, sources, transcription pipeline. No UI.
//   • VocatecaQwen      — optional Qwen3-ASR engine (MLX, macOS 15+, Apple Silicon).
//   • VocatecaParakeet  — optional Parakeet-TDT engine (FluidAudio/CoreML/ANE).
//   • vocateca-cli      — CLI executable (`--json` everywhere) + `mcp` stdio server.
//
// The proprietary macOS app (SwiftUI/AppKit UX), the Pro automation runner,
// and the account/entitlement/backend integration are NOT part of this package.
let package = Package(
    name: "VocatecaOpenCore",
    defaultLocalization: "en",
    platforms: [
        // macOS 15 for the optional Qwen3-ASR engine (soniqo/speech-swift uses
        // MLState, macOS 15+). WhisperKit + all core code remain the universal
        // baseline; Qwen is gated to capable Apple-Silicon Macs at runtime.
        .macOS(.v15)
    ],
    products: [
        .library(name: "VocatecaCore", targets: ["VocatecaCore"]),
        .library(name: "VocatecaQwen", targets: ["VocatecaQwen"]),
        .library(name: "VocatecaParakeet", targets: ["VocatecaParakeet"]),
        .executable(name: "vocateca-cli", targets: ["vocateca-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.0.0"),
        .package(url: "https://github.com/nmdias/FeedKit.git", from: "9.1.2"),
        // Optional Qwen3-ASR engine (loads mlx-community/Qwen3-ASR-1.7B-bf16).
        .package(url: "https://github.com/soniqo/speech-swift", exact: "0.0.21"),
        // On-device Parakeet-TDT (CoreML/ANE).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.4"),
    ],
    targets: [
        .target(
            name: "VocatecaCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FeedKit", package: "FeedKit"),
            ]
        ),
        .target(
            name: "VocatecaQwen",
            dependencies: [
                "VocatecaCore",
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
            ]
        ),
        .target(
            name: "VocatecaParakeet",
            dependencies: [
                "VocatecaCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(
            name: "vocateca-cli",
            dependencies: ["VocatecaCore", "VocatecaQwen", "VocatecaParakeet"]
        ),
        .testTarget(
            name: "VocatecaCoreTests",
            dependencies: ["VocatecaCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "VocatecaQwenTests",
            dependencies: ["VocatecaQwen", "VocatecaCore"]
        ),
        .testTarget(
            name: "VocatecaParakeetTests",
            dependencies: ["VocatecaParakeet", "VocatecaCore"]
        ),
    ]
)
