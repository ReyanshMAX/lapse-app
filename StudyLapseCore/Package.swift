// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StudyLapseCore",
    products: [
        .library(name: "StudyLapseCore", targets: ["StudyLapseCore"])
    ],
    targets: [
        .target(name: "StudyLapseCore"),
        .testTarget(name: "StudyLapseCoreTests", dependencies: ["StudyLapseCore"])
    ]
)
