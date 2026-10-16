// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentDeck",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that reads agents' files or builds `claude` commands. No UI.
        .target(name: "AgentDeckCore"),
        .executableTarget(name: "AgentDeck", dependencies: ["AgentDeckCore"]),
    ]
)
