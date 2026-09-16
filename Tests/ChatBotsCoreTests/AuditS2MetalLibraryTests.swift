// ChatBotsCoreTests — the Metal library this build produced is real (A135)
//
// Two comments in this repository said mlx-swift's SwiftPM build does not compile the Metal kernels —
// `tools/make-app.sh` used that as the reason for downloading MLX's release `mlx.metallib`, and
// `tools/fetch-metal.sh` opened with it. Under Xcode 27 that is false: with the Metal toolchain
// installed the build compiles every kernel into
// `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`, and `make-app.sh` now installs that file
// into the app instead of downloading one.
//
// This is the guard on that choice, and it reads the artefact rather than the code: the file is opened
// as a Metal library, so it has to exist and be a valid library, and the kernels MLX will ask for have
// to be in it. Whoever reads this next: the first version of this test copied the metallib beside the
// test binary so that MLX would load it. That works — and it breaks the build, because the next
// `codesign` of the test bundle fails with "code object is not signed at all: …/mlx.metallib", the same
// trap `make-app.sh` records for the app. Nothing here writes anything.

import Foundation
import Metal
import Testing

@Suite("The Metal library the build produces (A135)")
struct MetalLibraryTests {

    /// The metallib the build produced, found from the test bundle's own location: SwiftPM puts the
    /// resource bundle in its `Contents/Resources/`, and the products directory is one level above the
    /// bundle.
    private func builtMetallib() -> URL? {
        let bundle = Bundle(for: MetalLibraryMarker.self)
        let candidates = [
            bundle.bundleURL
                .appending(
                    path: "Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"),
            bundle.bundleURL.deletingLastPathComponent()
                .appending(path: "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"),
            bundle.resourceURL?
                .appending(path: "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @Test("The build compiled MLX's kernels into a library Metal can open")
    func theBuildsMetallibContainsMlxKernels() throws {
        let metallib = try #require(
            builtMetallib(),
            """
            the build produced no mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib — is the \
            Metal toolchain component installed? (see tools/check-metal.sh)
            """)
        let device = try #require(MTLCreateSystemDefaultDevice(), "no Metal device on this host")

        let library = try device.makeLibrary(URL: metallib)

        // A number rather than "some functions": MLX 0.31.6's kernel set is a few hundred entry points,
        // and a library that opened but was truncated fails here. Named kernels are checked too, because
        // the ones the release `mlx.metallib` was downloaded for are the steel attention kernels — and
        // the whole of the false claim was that the SwiftPM build does not produce them.
        #expect(library.functionNames.count > 200, "got \(library.functionNames.count) functions")
        #expect(
            library.functionNames.contains { $0.contains("steel") },
            "no steel kernel in the library the build produced")
    }

    @Test("The app installs the metallib the build produced, not a download")
    func theAppInstallsTheBuildsMetallib() throws {
        // `make-app.sh` copies `default.metallib` to `Contents/MacOS/mlx.metallib`, because
        // `mlx/backend/metal/device.cpp:136-180` looks beside the running binary first and the app's
        // engine is `Contents/MacOS/chatbots-cli`. The rule is a shell branch, so what is pinned here is
        // the branch: the file it copies from, the place it copies to, and the fallback it keeps. It
        // was written against the app bundle a real `make-app.sh` run produces.
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ChatBotsCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the package root
            .appending(path: "tools/make-app.sh")
        let text = try String(contentsOf: script, encoding: .utf8)

        #expect(
            text.contains("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"),
            "make-app.sh does not take its metallib from the build")
        #expect(
            text.contains("cp \"$BUILT_METALLIB\" \"$APP/Contents/MacOS/mlx.metallib\""),
            "make-app.sh does not install it where MLX looks")
        #expect(
            text.contains("fetch-metal.sh"),
            "the pinned download must stay as the fallback for a build that produced none")
    }
}

/// Only a token for `Bundle(for:)`, which is how the test bundle is located.
private final class MetalLibraryMarker {}
