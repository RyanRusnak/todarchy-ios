// swift-tools-version:5.10
import PackageDescription

// Local SPM package vendoring the reference libargon2 C implementation
// (P-H-C/phc-winner-argon2, tag 20190702). Used by todarchy to derive a
// per-user master key from a passphrase for encrypting per-project
// share keys inside the user's main doc.
//
// The C target compiles the portable reference fill-segment path
// (`ref.c`); SIMD-optimized `opt.c` is not vendored. `thread.c` is
// compiled with ARGON2_NO_THREADS — `parallelism > 1` therefore runs
// sequentially, which is fine for our usage (`parallelism = 1`).
let package = Package(
    name: "Argon2",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "Argon2", targets: ["Argon2"]),
    ],
    targets: [
        .target(
            name: "CArgon2",
            path: "Sources/CArgon2",
            publicHeadersPath: "include",
            cSettings: [
                // So `#include "blake2/blake2.h"` from core.c / ref.c resolves.
                .headerSearchPath("."),
                .define("ARGON2_NO_THREADS"),
            ]
        ),
        .target(
            name: "Argon2",
            dependencies: ["CArgon2"],
            path: "Sources/Argon2"
        ),
        .testTarget(
            name: "Argon2Tests",
            dependencies: ["Argon2"],
            path: "Tests/Argon2Tests"
        ),
    ]
)
