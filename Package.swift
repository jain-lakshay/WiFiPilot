// swift-tools-version: 6.0
import PackageDescription

// WiFiPilot has two halves:
//
//  * WiFiPilotCore — pure Swift: models, scoring, stability analysis, the decision
//    engine and persistence. No Apple frameworks, so it builds and is tested on any
//    Swift 6 platform (including Linux CI).
//  * WiFiPilot — the native macOS menu-bar app (SwiftUI, CoreWLAN, CoreLocation,
//    Network, ServiceManagement, Charts). Only declared on macOS, because those
//    frameworks do not exist elsewhere.

let coreTarget = Target.target(
    name: "WiFiPilotCore",
    path: "Sources/WiFiPilotCore",
    swiftSettings: [.swiftLanguageMode(.v6)]
)

let testTarget = Target.testTarget(
    name: "WiFiPilotCoreTests",
    dependencies: ["WiFiPilotCore"],
    path: "Tests/WiFiPilotCoreTests",
    swiftSettings: [.swiftLanguageMode(.v6)]
)

let simulationTarget = Target.executableTarget(
    name: "WiFiPilotSimulate",
    dependencies: ["WiFiPilotCore"],
    path: "Sources/WiFiPilotSimulate",
    swiftSettings: [.swiftLanguageMode(.v6)]
)

let coreProduct = Product.library(name: "WiFiPilotCore", targets: ["WiFiPilotCore"])
let simulationProduct = Product.executable(name: "wifipilot-simulate", targets: ["WiFiPilotSimulate"])

#if os(macOS)
let appTarget = Target.executableTarget(
    name: "WiFiPilot",
    dependencies: ["WiFiPilotCore"],
    path: "Sources/WiFiPilot",
    exclude: ["Info.plist"],
    swiftSettings: [.swiftLanguageMode(.v6)]
)
let appProduct = Product.executable(name: "WiFiPilot", targets: ["WiFiPilot"])
let products = [coreProduct, appProduct, simulationProduct]
let targets = [coreTarget, appTarget, simulationTarget, testTarget]
#else
let products = [coreProduct, simulationProduct]
let targets = [coreTarget, simulationTarget, testTarget]
#endif

let package = Package(
    name: "WiFiPilot",
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    targets: targets
)
