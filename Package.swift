// swift-tools-version: 5.8

import PackageDescription

let package = Package(
    name: "Bibbles",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Bibbles", targets: ["BibblesApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", exact: "2.55.3"),
        .package(url: "https://github.com/PostHog/posthog-ios.git", exact: "3.92.0")
    ],
    targets: [
        .executableTarget(
            name: "BibblesApp",
            dependencies: [
                .product(name: "Auth", package: "supabase-swift"),
                .product(name: "PostHog", package: "posthog-ios")
            ],
            path: "Sources/BibblesApp"
        ),
        .testTarget(
            name: "BibblesAppTests",
            dependencies: ["BibblesApp"],
            path: "Tests/BibblesAppTests"
        )
    ]
)
