//
//  ObjModelTests.swift
//  ModelViewerTests
//

import Foundation
import Testing
@testable import ModelViewer

/// Resources that are looked up by a closure, which also records which paths were requested.
private final class ClosureModelResources: ModelResources {
    private let lookup: (String) -> Data?
    private(set) var requested: [String] = []

    init(_ lookup: @escaping (String) -> Data?) {
        self.lookup = lookup
    }

    func open(_ path: String) -> Data? {
        requested.append(path)
        return lookup(path)
    }
}

struct ObjModelTests {
    private static let cubePositions = "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nv 0 0 1\nv 1 0 1\nv 1 1 1\nv 0 1 1\n"
    private static let cubeFaces = "f 1 4 3 2\nf 5 6 7 8\nf 1 2 6 5\nf 2 3 7 6\nf 3 4 8 7\nf 4 1 5 8\n"

    private static func load(_ obj: String, _ resources: ModelResources = NoModelResources()) throws -> ObjModel {
        try ObjModel(data: Data(obj.utf8), resources: resources)
    }

    @Test func plainModel() throws {
        let model = try Self.load(Self.cubePositions + Self.cubeFaces)
        #expect(model.vertexCount == 8)
        #expect(model.indexCount == 36)
        #expect(!model.hasMaterials)
        #expect(model.colors == nil)
        #expect(model.texCoords == nil)

        // Without normals in the file, each corner gets a smooth (unit) normal pointing away from the cube.
        for v in 0..<8 {
            var length: Float = 0
            for i in 0..<3 {
                let n = model.normals[v * 3 + i]
                let outward: Float = model.vertices[v * 3 + i] == 0 ? -1 : 1
                #expect(n * outward > 0.3, "Vertex \(v) normal \(i)")
                length += n * n
            }
            #expect(abs(length - 1) < 1e-5)
        }
    }

    @Test func faceFormats() throws {
        // A pentagon (split into 3 triangles) with negative (relative) indices, and a triangle with
        // texture coordinates and normals, which share a position with the pentagon.
        let obj = "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0.5 1.5 0\nv 0 1 0\n" +
            "vt 0 0\nvt 1 1\nvn 0 0 1\nvn 0 0 -1\n" +
            "f -5 -4 -3 -2 -1\n" +
            "f 1/1/2 3/2/2 2//1\n"
        let model = try Self.load(obj)
        #expect(model.indexCount == 12)
        // The triangle's corners differ from the pentagon's in texture coordinates or normals,
        // so they're separate vertices.
        #expect(model.vertexCount == 8)
        let indices = try #require(model.indices)
        #expect(Array(indices[0..<9]) == [0, 1, 2, 0, 2, 3, 0, 3, 4])
        #expect(Array(indices[9..<12]) == [5, 6, 7])
        // The given normal is used for the triangle's corner.
        #expect(model.normals[5 * 3 + 2] == -1)
    }

    @Test func sharedVertices() throws {
        // Corners with the same position, texture coordinate, and normal are the same vertex.
        let obj = Self.cubePositions + "vt 0 0\nvn 0 0 1\nf 1/1/1 2/1/1 3/1/1\nf 1/1/1 3/1/1 4/1/1\n"
        let model = try Self.load(obj)
        #expect(model.vertexCount == 4)
        #expect(model.indices.map { Array($0[0..<6]) } == [0, 1, 2, 0, 2, 3])
    }

    @Test func invalidFace() {
        #expect(throws: (any Error).self) { try Self.load("v 0 0 0\nv 1 0 0\nf 1 2 3\n") }
        #expect(throws: (any Error).self) { try Self.load("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 -4\n") }
    }

    @Test func vertexColors() throws {
        // Colors from 0 to 1, and vertices without colors are white.
        var model = try Self.load("v 0 0 0 1 0 0\nv 1 0 0\nv 0 1 0 0 0.5 1\nf 1 2 3\n")
        #expect(model.hasMaterials)
        #expect(model.colors.map { Array($0[0..<12]) } == [1, 0, 0, 1, 1, 1, 1, 1, 0, 0.5, 1, 1])

        // Colors from 0 to 255
        model = try Self.load("v 0 0 0 255 0 0\nv 1 0 0 0 51 0\nv 0 1 0 0 0 255\nf 1 2 3\n")
        let expected: [Float] = [1, 0, 0, 1, 0, 0.2, 0, 1, 0, 0, 1, 1]
        let colors = try #require(model.colors)
        for i in 0..<12 {
            #expect(abs(colors[i] - expected[i]) < 1e-6)
        }
    }

    @Test func materials() throws {
        let obj = "mtllib materials.mtl\n" + Self.cubePositions +
            "vt 0 0\nvt 1 0\nvt 1 1\nvt 0 1\n" +
            "usemtl wood\n" +
            "f 1/1 4/2 3/3 2/4\nf 5/1 6/2 7/3 8/4\n" +
            "usemtl glass pane\n" +
            "f 1 2 6 5\n" +
            "usemtl undefined\n" +
            "f 2 3 7 6\n" +
            "usemtl wood\n" +
            "f 3/1 4/2 8/3 7/4\n"
        let mtl = "# materials\n" +
            "newmtl wood\n" +
            "Ka 1 1 1\nKs 0.5 0.4 0.3\nNs 250\nillum 2\n" +
            "map_Kd -s 2 3 -o 0.5 0.25 -clamp on textures\\wood grain.png\n" +
            "newmtl glass pane\n" +
            "Kd 0.1 0.2 0.3\nd 0.25\nTr 0.9\nillum 1\nKe 0.1 0.1 0.1\n"
        let texture = Data([1, 2, 3, 4])
        let files: [String: Data] = ["materials.mtl": Data(mtl.utf8), "textures/wood grain.png": texture]
        let resources = ClosureModelResources { files[ModelResourcePath.normalize($0)] }
        let model = try Self.load(obj, resources)
        #expect(resources.requested == ["materials.mtl", "textures\\wood grain.png"])

        // Faces are grouped by material, in the order that the materials are first used.
        let parts = model.parts
        try #require(parts.count == 3)
        #expect(parts[0].material.name == "wood")
        #expect(parts[0].first == 0)
        #expect(parts[0].count == 18)
        #expect(parts[1].material.name == "glass pane")
        #expect(parts[1].first == 18)
        #expect(parts[1].count == 6)
        #expect(parts[2].material.name == "undefined")
        #expect(parts[2].first == 24)
        #expect(parts[2].count == 6)

        let wood = parts[0].material
        #expect(wood.diffuseTexture == texture)
        // A textured material without a diffuse color shows its texture as is.
        #expect(wood.diffuseColor == SIMD3(1, 1, 1))
        #expect(wood.specularColor == SIMD3(0.5, 0.4, 0.3))
        #expect(wood.shininess == 250)
        #expect(wood.lighting == .specular)
        #expect(wood.textureScale == SIMD2(2, 3))
        #expect(wood.textureOffset == SIMD2(0.5, 0.25))

        let glass = parts[1].material
        #expect(glass.diffuseTexture == nil)
        #expect(glass.diffuseColor == SIMD3(0.1, 0.2, 0.3))
        #expect(glass.emissiveColor == SIMD3(0.1, 0.1, 0.1))
        // "d" takes precedence over "Tr".
        #expect(glass.opacity == 0.25)
        #expect(glass.lighting == .diffuse)

        // A material that isn't defined gets the default gray.
        #expect(parts[2].material.diffuseColor == SIMD3(0.8, 0.8, 0.8))

        // Since there's a texture, texture coordinates are included.
        let texCoords = try #require(model.texCoords)
        let vertex = Int(try #require(model.indices)[1])
        #expect(Array(texCoords[(vertex * 2)..<(vertex * 2 + 2)]) == [1, 0])
    }

    @Test func materialLibraryNames() throws {
        let files: [String: String] = [
            "a.mtl": "newmtl red\nKd 1 0 0\n",
            "b.mtl": "newmtl green\nKd 0 1 0\nTr 0.25\n",
            "my materials.mtl": "newmtl blue\nKd 0 0 1\nTr 1\n",
        ]
        let resources = ClosureModelResources { files[$0].map { Data($0.utf8) } }
        // Several libraries on one line, and a library whose name has a space.
        let obj = "mtllib a.mtl b.mtl\nmtllib my materials.mtl\n" + Self.cubePositions +
            "usemtl red\nf 1 2 3\nusemtl green\nf 1 3 4\nusemtl blue\nf 5 6 7\n"
        let parts = try Self.load(obj, resources).parts
        try #require(parts.count == 3)
        #expect(parts[0].material.diffuseColor == SIMD3(1, 0, 0))
        #expect(parts[1].material.diffuseColor == SIMD3(0, 1, 0))
        #expect(parts[1].material.opacity == 0.75)
        #expect(parts[2].material.diffuseColor == SIMD3(0, 0, 1))
        // Some exporters write "Tr 1" for opaque materials.
        #expect(parts[2].material.opacity == 1)
    }

    @Test func missingMaterialLibrary() throws {
        // Without its materials, the model is drawn like a model without materials.
        let resources = ClosureModelResources { _ in nil }
        let model = try Self.load("mtllib missing.mtl\n" + Self.cubePositions + "usemtl red\n" + Self.cubeFaces, resources)
        #expect(resources.requested == ["missing.mtl"])
        #expect(model.parts.isEmpty)
        #expect(!model.hasMaterials)
        #expect(model.indexCount == 36)
    }
}
