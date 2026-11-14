// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ProxyGauge",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        .library(name: "ProxyGaugeCore", targets: ["ProxyGaugeCore"]),
        .library(name: "ProxyGaugeStore", targets: ["ProxyGaugeStore"]),
        .library(name: "ProxyGaugeSession", targets: ["ProxyGaugeSession"])
    ],
    targets: [
        .target(name: "ProxyGaugeCore"),
        .target(name: "ProxyGaugeStore", dependencies: ["ProxyGaugeCore"]),
        .target(name: "ProxyGaugeSession", dependencies: ["ProxyGaugeCore", "ProxyGaugeStore"]),
        .testTarget(name: "ProxyGaugeCoreTests", dependencies: ["ProxyGaugeCore"]),
        .testTarget(name: "ProxyGaugeStoreTests", dependencies: ["ProxyGaugeStore", "ProxyGaugeCore"]),
        .testTarget(name: "ProxyGaugeSessionTests", dependencies: ["ProxyGaugeSession", "ProxyGaugeStore", "ProxyGaugeCore"])
    ],
    swiftLanguageModes: [.v6]
)
