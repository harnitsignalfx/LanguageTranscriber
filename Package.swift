// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LanguageTranscriber",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "LanguageTranscriber", targets: ["LanguageTranscriber"])
    ],
    targets: [
        .executableTarget(
            name: "LanguageTranscriber",
            path: "Sources/LanguageTranscriber"
        )
    ]
)
