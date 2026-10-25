// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AppeekyAnalytics",
    platforms: [
        .iOS(.v15),
        // The client logic also builds on macOS so its unit tests run on a Mac host.
        .macOS(.v12),
    ],
    products: [
        .library(name: "AppeekyAnalytics", targets: ["AppeekyAnalytics"]),
    ],
    targets: [
        .target(
            name: "AppeekyAnalytics",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "AppeekyAnalyticsTests",
            dependencies: ["AppeekyAnalytics"],
            exclude: ["Fixtures"]
        ),
    ]
)
