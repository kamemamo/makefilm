// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MakeFilm",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MakeFilm",
            path: "Sources/MakeFilm"
        )
    ]
)
