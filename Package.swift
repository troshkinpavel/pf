// swift-tools-version: 5.10
// PFCore: the platform-neutral core shared by PF Terminal clients (macOS app in this
// repository; the iPhone app consumes it by URL). It lives at the repository root because
// SwiftPM only resolves remote packages whose manifest is at the root. The macOS Xcode
// project uses this same package locally, so there is one copy of the code.
import PackageDescription

let package = Package(
    name: "PFCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Models, accounting, analytics, market data, persistence, CloudKit sync, formatting,
        // widget snapshot model. Foundation / CloudKit / SwiftData only; no UI frameworks.
        .library(name: "PFCore", targets: ["PFCore"]),
        // Shared SwiftUI: design tokens, widget layouts, share card.
        .library(name: "PFCoreUI", targets: ["PFCoreUI"]),
        // In-memory CloudKit stand-in and sync host for clients' tests.
        .library(name: "PFCoreTestSupport", targets: ["PFCoreTestSupport"]),
    ],
    targets: [
        .target(name: "PFCore", path: "PFCore"),
        .target(name: "PFCoreUI", dependencies: ["PFCore"], path: "PFCoreUI"),
        .target(name: "PFCoreTestSupport", dependencies: ["PFCore"], path: "PFCoreTestSupport"),
        .testTarget(name: "PFCoreTests", dependencies: ["PFCore", "PFCoreTestSupport"], path: "PFCoreTests"),
    ]
)
