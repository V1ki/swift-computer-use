// swift-tools-version: 6.0
// SwiftCUA — a from-scratch Swift reimplementation of the macOS "Codex Computer Use" service.
//
// Target layout:
//   CUACore     shared models, JSON-RPC wire protocol, engine contract, logging
//   CUAEngine   macOS engine: accessibility tree, screenshots, input synthesis, app/window catalogs
//   CUAService  background service: unix-socket server, session authorization, request router
//   CUAClient   CLI + MCP stdio server
import PackageDescription

let package = Package(
    name: "SwiftCUA",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "CUACore", targets: ["CUACore"]),
        .library(name: "CUAEngine", targets: ["CUAEngine"]),
        .executable(name: "cua-service", targets: ["CUAService"]),
        .executable(name: "cua", targets: ["CUAClient"]),
    ],
    targets: [
        .target(name: "CUACore"),
        .target(name: "CUAEngine", dependencies: ["CUACore"]),
        .executableTarget(name: "CUAService", dependencies: ["CUACore", "CUAEngine"]),
        .executableTarget(name: "CUAClient", dependencies: ["CUACore"]),
        .testTarget(name: "CUACoreTests", dependencies: ["CUACore"]),
        .testTarget(name: "CUAEngineTests", dependencies: ["CUAEngine", "CUACore"]),
        .testTarget(name: "CUAServiceTests", dependencies: ["CUAService", "CUAEngine", "CUACore"]),
        .testTarget(name: "CUAClientTests", dependencies: ["CUAClient", "CUACore"]),
    ]
)
