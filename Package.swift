// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TrailAdvisor",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.0.0"),
        .package(url: "https://github.com/Outdooractive/gis-tools", from: "2.0.0"),
    ],
    targets: [
        // libsqlite3 via a modulemap rather than `import SQLite3`, which only exists on
        // Apple platforms. See Sources/CSQLite/module.modulemap.
        .systemLibrary(
            name: "CSQLite",
            providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite3"])]),
        .executableTarget(
            name: "TrailAdvisor",
            dependencies: [
                "CSQLite",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "GISTools", package: "gis-tools"),
            ]),
    ]
)
