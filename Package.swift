// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentDesk", targets: ["AgentDesk"]),
        .executable(name: "agentdesk-files", targets: ["AgentDeskFiles"])
    ],
    targets: [
        .target(name: "AgentDeskCore"),
        .executableTarget(name: "AgentDesk", dependencies: ["AgentDeskCore"]),
        .executableTarget(name: "AgentDeskFiles", dependencies: ["AgentDeskCore"]),
        .testTarget(name: "AgentDeskCoreTests", dependencies: ["AgentDeskCore"], resources: [.copy("Fixtures")])
    ]
)
