// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "XCLogParser",
    platforms: [.macOS(.v10_13)],
    products: [
    	.executable(name: "xclogparser", targets: ["XCLogParserApp"]),
        .executable(name: "xclogparser-bench", targets: ["XCLogParserBench"]),
        .executable(name: "xclogparser-loggen", targets: ["XCLogParserLogGenApp"]),
        .library(name: "XCLogParser", targets: ["XCLogParser"])
    ],
    dependencies: [
        .package(url: "https://github.com/1024jp/GzipSwift", from: "5.1.0"),
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", .exact("1.3.3")),
        .package(url: "https://github.com/kylef/PathKit.git", from: "1.0.1"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.0.0"),
    ],
    targets: [
        .target(
            name:"XcodeHasher",
            dependencies: ["CryptoSwift"]
        ),
        .target(
            name: "XCLogParser",
            dependencies: [
                .product(name: "Gzip", package: "GzipSwift"),
                "XcodeHasher",
                "PathKit"
            ]
        ),
        .executableTarget(
            name: "XCLogParserApp",
            dependencies: [
                "XCLogParser",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        // Hooks the Swift runtime's allocation and reference-counting pointers so the
        // benchmark can report exact counts. Deliberately a dependency of the benchmark
        // target only - it must never be linked into the library or the CLI.
        .target(
            name: "CAllocationCounters"
        ),
        .executableTarget(
            name: "XCLogParserBench",
            dependencies: [
                "XCLogParser",
                "CAllocationCounters",
                .product(name: "Gzip", package: "GzipSwift")
            ]
        ),
        // Split library + thin executable so the tests can import the generator; a test target
        // cannot depend on an executable target.
        .target(
            name: "XCLogParserLogGen",
            dependencies: [
                "XCLogParser",
                .product(name: "Gzip", package: "GzipSwift"),
                .product(name: "Yams", package: "Yams")
            ]
        ),
        .executableTarget(
            name: "XCLogParserLogGenApp",
            dependencies: ["XCLogParserLogGen"]
        ),
        .testTarget(
            name: "XCLogParserLogGenTests",
            dependencies: [
                "XCLogParserLogGen",
                "XCLogParser",
                .product(name: "Gzip", package: "GzipSwift")
            ]
        ),
        // Separate from XCLogParserTests so the runtime hooks are linked only into a binary that exists
        // to test them. Adding CAllocationCounters to the main test target would leave the allocation
        // and retain/release pointers hooked for every other test in the suite.
        .testTarget(
            name: "CAllocationCountersTests",
            dependencies: ["CAllocationCounters"]
        ),
        .testTarget(
            name: "XCLogParserTests",
            dependencies: [
                "XCLogParser",
                .product(name: "Gzip", package: "GzipSwift")
            ]
        ),
    ]

)
