//
//  PlyModelTests.swift
//  ModelViewerTests
//

import Foundation
import Testing
@testable import ModelViewer

struct PlyModelTests {
    private static func load(_ text: String) throws -> PlyModel {
        try PlyModel(data: Data(text.utf8))
    }

    @Test func loadAsciiModel() throws {
        var model = try PlyModel(data: try TestResources.data("dolphins.ply"))
        #expect(model.vertexCount == 855)

        model = try PlyModel(data: try TestResources.data("ellell.ply"))
        #expect(model.vertexCount == 20)
        // Meshes without colors are drawn with the default colors.
        #expect(model.colors == nil)
        #expect(!model.hasMaterials)
        #expect(!model.isPointCloud)
        // 18 quads, as two triangles each.
        #expect(model.indexCount == 18 * 6)
    }

    @Test func vertexColors() throws {
        let ply = "ply\nformat ascii 1.0\nelement vertex 3\nproperty float x\nproperty float y\nproperty float z\n" +
            "property uchar red\nproperty uchar green\nproperty uchar blue\nelement face 1\n" +
            "property list uchar int vertex_indices\nend_header\n" +
            "0 0 0 255 0 0\n1 0 0 0 255 0\n0 1 0 0 0 255\n3 0 1 2\n"
        let model = try Self.load(ply)
        #expect(model.hasMaterials)
        #expect(model.colors == [1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 1, 1])
        #expect(model.indices == [0, 1, 2])
    }

    @Test func pointCloud() throws {
        let ply = "ply\nformat ascii 1.0\nelement vertex 2\nproperty float x\nproperty float y\nproperty float z\n" +
            "end_header\n0 0 0\n1 2 3\n"
        let model = try Self.load(ply)
        #expect(model.isPointCloud)
        #expect(model.vertexCount == 2)
        // Points without colors are white.
        #expect(model.colors == [1, 1, 1, 1, 1, 1, 1, 1])
    }

    @Test func binaryModel() throws {
        // The same triangle in both byte orders, with a quad and an extra property in each face.
        for bigEndian in [false, true] {
            var data = Data(("ply\nformat binary_\(bigEndian ? "big" : "little")_endian 1.0\n" +
                "element vertex 4\nproperty float x\nproperty float y\nproperty float z\n" +
                "property uchar red\nproperty uchar green\nproperty uchar blue\n" +
                "element face 1\nproperty list uchar int vertex_indices\nproperty uchar flags\nend_header\n").utf8)
            func appendFloat(_ value: Float) {
                let bits = bigEndian ? value.bitPattern.bigEndian : value.bitPattern.littleEndian
                withUnsafeBytes(of: bits) { data.append(contentsOf: $0) }
            }
            func appendInt(_ value: Int32) {
                let bits = bigEndian ? value.bigEndian : value.littleEndian
                withUnsafeBytes(of: bits) { data.append(contentsOf: $0) }
            }
            let positions: [[Float]] = [[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0]]
            for p in positions {
                p.forEach(appendFloat)
                data.append(contentsOf: [255, 128, 0])
            }
            data.append(4)
            [0, 1, 2, 3].forEach(appendInt)
            data.append(7)

            let model = try PlyModel(data: data)
            #expect(model.vertexCount == 4)
            #expect(model.vertices == positions.flatMap { $0 })
            #expect(model.indices == [0, 1, 2, 0, 2, 3])
            #expect(model.colors?.prefix(4) == [1, Float(128) / 255, 0, 1])
            // Faces face +Z.
            #expect(model.normals[2] > 0)
        }
    }

    @Test func invalidFace() {
        let ply = "ply\nformat ascii 1.0\nelement vertex 3\nproperty float x\nproperty float y\nproperty float z\n" +
            "element face 1\nproperty list uchar int vertex_indices\nend_header\n0 0 0\n1 0 0\n0 1 0\n3 0 1 5\n"
        #expect(throws: (any Error).self) { try Self.load(ply) }
    }
}
