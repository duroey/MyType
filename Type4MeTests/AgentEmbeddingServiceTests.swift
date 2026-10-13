import Foundation
import XCTest
@testable import Type4Me

@MainActor
final class AgentEmbeddingServiceTests: XCTestCase {
    /// Verifies a complete synthetic cache is accepted without starting the embedding runtime.
    ///
    /// Raises:
    ///   Error: The temporary fixture could not be prepared.
    func testCompleteModelCacheIsAccepted() throws {
        try withFixture { fixture in
            XCTAssertTrue(fixture.isValid)
        }
    }

    /// Verifies a missing manifest-referenced blob prevents runtime startup.
    ///
    /// Raises:
    ///   Error: The temporary fixture could not be prepared or changed.
    func testMissingModelBlobIsRejected() throws {
        try withFixture { fixture in
            try FileManager.default.removeItem(at: fixture.layer)
            XCTAssertFalse(fixture.isValid)
        }
    }

    /// Verifies a truncated blob is rejected even though its expected filename exists.
    ///
    /// Raises:
    ///   Error: The temporary fixture could not be prepared or changed.
    func testIncorrectModelBlobSizeIsRejected() throws {
        try withFixture { fixture in
            try Data([1]).write(to: fixture.layer)
            XCTAssertFalse(fixture.isValid)
        }
    }

    /// Verifies manifest and digest paths cannot escape the synthetic model directory.
    ///
    /// Raises:
    ///   Error: The temporary fixture could not be prepared or changed.
    func testManifestAndDigestTraversalAreRejected() throws {
        try withFixture { fixture in
            let outside = fixture.root.appendingPathComponent("outside.json")
            try fixture.manifestData.write(to: outside)
            XCTAssertFalse(AgentEmbeddingService.modelFilesExist(in: fixture.models, manifestPath: "../outside.json"))
            XCTAssertFalse(AgentEmbeddingService.modelFilesExist(in: fixture.models, manifestPath: outside.path))
            let invalid = try fixture.makeManifest(layerDigest: "sha256:../../outside.json")
            try invalid.write(to: fixture.manifest)
            XCTAssertFalse(fixture.isValid)
        }
    }

    /// Verifies valid-looking manifests and blobs reached through escaping symlinks are rejected.
    ///
    /// Raises:
    ///   Error: The temporary fixture could not be prepared or linked.
    func testEscapingManifestAndBlobSymlinksAreRejected() throws {
        try withFixture { fixture in
            let manager = FileManager.default
            let outsideManifest = fixture.root.appendingPathComponent("outside.json")
            try fixture.manifestData.write(to: outsideManifest)
            try manager.removeItem(at: fixture.manifest)
            try manager.createSymbolicLink(at: fixture.manifest, withDestinationURL: outsideManifest)
            XCTAssertFalse(fixture.isValid)
            try manager.removeItem(at: fixture.manifest)
            try fixture.manifestData.write(to: fixture.manifest)

            let outsideBlob = fixture.root.appendingPathComponent("outside-blob")
            try Data([1, 2, 3, 4]).write(to: outsideBlob)
            try manager.removeItem(at: fixture.layer)
            try manager.createSymbolicLink(at: fixture.layer, withDestinationURL: outsideBlob)
            XCTAssertFalse(fixture.isValid)
        }
    }

    /// Provides an isolated cache and always removes its synthetic files after the assertion body.
    ///
    /// Args:
    ///   body: Assertions that may inspect or mutate only the temporary fixture.
    ///
    /// Raises:
    ///   Error: Fixture preparation or the supplied assertion body failed.
    private func withFixture(_ body: (ModelFixture) throws -> Void) throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("mytype-embedding-test-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let fixture = ModelFixture(root: root)
        try manager.createDirectory(at: fixture.manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createDirectory(at: fixture.layer.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: fixture.config)
        try Data([1, 2, 3, 4]).write(to: fixture.layer)
        try fixture.manifestData.write(to: fixture.manifest)
        try body(fixture)
    }

    private struct ModelFixture {
        let root: URL
        let manifestPath = "manifests/registry.ollama.ai/library/qwen3-embedding/0.6b"
        let configDigest = "sha256:" + String(repeating: "a", count: 64)
        let layerDigest = "sha256:" + String(repeating: "b", count: 64)
        var models: URL { root.appendingPathComponent("models") }
        var manifest: URL { models.appendingPathComponent(manifestPath) }
        var config: URL { models.appendingPathComponent("blobs/" + configDigest.replacingOccurrences(of: ":", with: "-")) }
        var layer: URL { models.appendingPathComponent("blobs/" + layerDigest.replacingOccurrences(of: ":", with: "-")) }
        var manifestData: Data { get throws { try makeManifest(layerDigest: layerDigest) } }
        @MainActor var isValid: Bool { AgentEmbeddingService.modelFilesExist(in: models, manifestPath: manifestPath) }

        /// Encodes small synthetic references using Ollama's manifest field names.
        ///
        /// Args:
        ///   layerDigest: Valid or deliberately malformed digest used by the fixture.
        ///
        /// Returns:
        ///   Manifest bytes referencing only tiny fixture blobs.
        ///
        /// Raises:
        ///   Error: The fixture dictionary could not be encoded.
        func makeManifest(layerDigest: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "config": ["digest": configDigest, "size": 3],
                "layers": [["digest": layerDigest, "size": 4]],
            ])
        }
    }
}
