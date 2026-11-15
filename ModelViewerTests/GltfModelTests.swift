//
//  GltfModelTests.swift
//  ModelViewerTests
//

import Foundation
import Testing
@testable import ModelViewer

struct GltfModelTests {
    private static let tolerance: Float = 1e-4
    private static let image: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 13, 10, 26, 10, 1, 2, 3, 4, 5]
    private static let triangle: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
    private static let triangleNormals: [Float] = [0, 0, 1, 0, 0, 1, 0, 0, 1]
    /// sin(45 degrees), for quaternions of rotations by 90 degrees.
    private static let s = 0.5.squareRoot()

    private static let unsignedByte = 5121
    private static let unsignedShort = 5123

    @Test func nodesAndMaterials() throws {
        let glb = Glb()
        let positions = glb.floats("VEC3", Self.triangle)
        let normals = glb.floats("VEC3", Self.triangleNormals)
        let indices = glb.ints(Self.unsignedShort, "SCALAR", false, [0, 1, 2])
        // Node 0 has a child, which is rotated (90 degrees about Y) and scaled, and the next node
        // has a matrix (a translation); the last node isn't in the scene.
        let data = glb.build("""
            "scene": 0,
            "scenes": [{"nodes": [0, 2]}],
            "nodes": [
              {"translation": [10, 0, 0], "children": [1]},
              {"rotation": [0, \(Self.s), 0, \(Self.s)], "scale": [2, 2, 2], "mesh": 0},
              {"matrix": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 5, 0, 1], "mesh": 0},
              {"mesh": 0}
            ],
            "meshes": [{"primitives": [{"attributes": {"POSITION": \(positions), "NORMAL": \(normals)}, "indices": \(indices), "material": 0}]}],
            "materials": [{
              "name": "Gray \\"1\\" \\u00e9",
              "pbrMetallicRoughness": {"baseColorFactor": [0.21404114, 0.21404114, 0.21404114, 1], "metallicFactor": 0, "roughnessFactor": 0.5},
              "emissiveFactor": [1, 0, 0]
            }]
            """)
        let model = try GltfModel(data: data, resources: nil)

        #expect(model.vertexCount == 6)
        assertPositions(model, 0, [10, 0, 0, 10, 0, -2, 10, 2, 0])
        assertPositions(model, 3, [0, 5, 0, 1, 5, 0, 0, 6, 0])
        for v in 0..<3 {
            assertNormal(model, v, 1, 0, 0)
            assertNormal(model, v + 3, 0, 0, 1)
        }
        assertIndices(model, [0, 1, 2, 3, 4, 5])
        #expect(model.texCoords == nil)
        #expect(model.colors == nil)

        #expect(model.parts.count == 1)
        let material = model.parts[0].material
        #expect(material.name == "Gray \"1\" \u{e9}")
        // Linear colors are converted to sRGB.
        assertClose(material.diffuseColor, SIMD3(0.5, 0.5, 0.5), 1e-3)
        assertClose(material.emissiveColor, SIMD3(1, 0, 0))
        // The highlight of a dielectric with a roughness of 0.5.
        #expect(abs(material.shininess - 30) < Self.tolerance)
        let specular: Float = 0.04 * (30 + 8) / 8 * 0.75
        assertClose(material.specularColor, SIMD3(repeating: specular))
        #expect(material.alphaMode == .opaque)
    }

    @Test func texturesAndAlpha() throws {
        let glb = Glb()
        let positions = glb.floats("VEC3", [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0])
        let normals = glb.floats("VEC3", [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1])
        let texCoords = glb.floats("VEC2", [0, 0, 1, 0, 1, 1, 0, 1])
        let colors = glb.ints(Self.unsignedByte, "VEC4", true, [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 51, 255, 255, 255, 255])
        let indices = glb.ints(Self.unsignedShort, "SCALAR", false, [0, 1, 2, 0, 2, 3])
        let image = glb.view(Self.image)
        let data = glb.build("""
            "extensionsUsed": ["KHR_texture_transform", "KHR_materials_pbrSpecularGlossiness"],
            "extensionsRequired": ["KHR_texture_transform"],
            "scenes": [{"nodes": [0]}],
            "nodes": [{"mesh": 0}],
            "meshes": [{"primitives": [
              {"attributes": {"POSITION": \(positions), "NORMAL": \(normals), "TEXCOORD_0": \(texCoords)}, "indices": \(indices), "material": 0},
              {"attributes": {"POSITION": \(positions), "NORMAL": \(normals), "COLOR_0": \(colors)}, "indices": \(indices), "material": 1}
            ]}],
            "materials": [
              {
                "name": "Leaves",
                "pbrMetallicRoughness": {"baseColorTexture": {"index": 0, "extensions": {"KHR_texture_transform": {"offset": [0.5, 0], "scale": [2, 1]}}}},
                "alphaMode": "MASK",
                "alphaCutoff": 0.25
              },
              {
                "extensions": {"KHR_materials_pbrSpecularGlossiness": {"diffuseFactor": [1, 1, 1, 0.5], "specularFactor": [1, 1, 1], "glossinessFactor": 0.5}},
                "alphaMode": "BLEND"
              }
            ],
            "textures": [{"source": 0, "sampler": 0}],
            "samplers": [{}],
            "images": [{"bufferView": \(image), "mimeType": "image/png", "name": "leaves.png"}]
            """)
        let model = try GltfModel(data: data, resources: nil)

        #expect(model.vertexCount == 8)
        assertIndices(model, [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7])
        let parts = model.parts
        #expect(parts.count == 2)
        let leaves = parts[0].material
        #expect(leaves.diffuseTexture == Data(Self.image))
        #expect(leaves.diffuseTextureName == "leaves.png")
        #expect(leaves.alphaMode == .mask)
        #expect(abs(leaves.alphaCutoff - 0.25) < Self.tolerance)
        // The texture coordinates are scaled and offset, and then flipped, since glTF's origin is at the top left.
        assertTexCoords(model, 0, [0.5, 1, 2.5, 1, 2.5, 0, 0.5, 0])

        // The specular-glossiness extension is used without other properties.
        let blended = parts[1].material
        #expect(blended.alphaMode == .blend)
        #expect(abs(blended.opacity - 0.5) < Self.tolerance)
        #expect(abs(blended.shininess - 30) < Self.tolerance)
        assertClose(blended.specularColor, SIMD3(1, 1, 1))
        #expect(blended.diffuseTexture == nil)
        // Vertex colors are converted to sRGB (except for alpha), and vertices without colors are white.
        assertColor(model, 0, [1, 1, 1, 1])
        assertColor(model, 4, [1, 0, 0, 1])
        assertColor(model, 6, [0, 0, 1, 0.2])
    }

    @Test func stripsFansAndFlatNormals() throws {
        let glb = Glb()
        let stripPositions = glb.floats("VEC3", [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0])
        let fanPositions = glb.floats("VEC3", [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0])
        let fanNormals = glb.floats("VEC3", [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1])
        let fanIndices = glb.ints(Self.unsignedByte, "SCALAR", false, [0, 1, 2, 3])
        // A strip without normals, in a mirrored node, and a fan (with points, which aren't shown).
        let data = glb.build("""
            "scenes": [{"nodes": [0, 1]}],
            "nodes": [{"mesh": 0, "scale": [-1, 1, 1]}, {"mesh": 1}],
            "meshes": [
              {"primitives": [{"attributes": {"POSITION": \(stripPositions)}, "mode": 5}]},
              {"primitives": [
                {"attributes": {"POSITION": \(fanPositions), "NORMAL": \(fanNormals)}, "indices": \(fanIndices), "mode": 6},
                {"attributes": {"POSITION": \(fanPositions)}, "mode": 0}
              ]}
            ]
            """)
        let model = try GltfModel(data: data, resources: nil)

        // The triangles of the strip have their own vertices, and their corners are reversed, since they're mirrored.
        #expect(model.vertexCount == 10)
        assertPositions(model, 0, [0, 0, 0, 0, 1, 0, -1, 0, 0, 0, 1, 0, -1, 1, 0, -1, 0, 0])
        for v in 0..<10 {
            assertNormal(model, v, 0, 0, 1)
        }
        assertIndices(model, [0, 1, 2, 3, 4, 5, 6, 7, 8, 6, 8, 9])
        #expect(model.parts.isEmpty)
    }

    @Test func skinning() throws {
        let glb = Glb()
        let positions = glb.floats("VEC3", [0, 0, 0, 6, 0, 0, 5, 1, 0])
        let normals = glb.floats("VEC3", Self.triangleNormals)
        let joints = glb.ints(Self.unsignedByte, "VEC4", false, [0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0])
        let weights = glb.floats("VEC4", [1, 0, 0, 0, 1, 0, 0, 0, 0.5, 0.5, 0, 0])
        // The first joint was bound at the origin, and the second at X = 5.
        let inverseBindMatrices = glb.floats("MAT4", [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1,
                                                      1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -5, 0, 0, 1])
        // The joints have moved up, and the second one is turned 90 degrees about Z. The transform
        // of the skinned mesh's node doesn't matter.
        let data = glb.build("""
            "scenes": [{"nodes": [0, 1]}],
            "nodes": [
              {"mesh": 0, "skin": 0, "translation": [100, 0, 0]},
              {"translation": [0, 10, 0], "children": [2]},
              {"translation": [5, 0, 0], "rotation": [0, 0, \(Self.s), \(Self.s)]}
            ],
            "skins": [{"joints": [1, 2], "inverseBindMatrices": \(inverseBindMatrices)}],
            "meshes": [{"primitives": [{"attributes": {"POSITION": \(positions), "NORMAL": \(normals), "JOINTS_0": \(joints), "WEIGHTS_0": \(weights)}}]}]
            """)
        let model = try GltfModel(data: data, resources: nil)

        // The last vertex is halfway between where the two joints put it.
        assertPositions(model, 0, [0, 10, 0, 5, 11, 0, 4.5, 10.5, 0])
        for v in 0..<3 {
            assertNormal(model, v, 0, 0, 1)
        }
    }

    @Test func morphTargetsAndSparseAccessors() throws {
        let glb = Glb()
        let positions = glb.floats("VEC3", Self.triangle)
        let sparseIndices = glb.view([2])
        let sparseValues = glb.view(Self.floatBytes([0, 0, 1]))
        // The first target moves the last vertex (with a sparse accessor, without a buffer view), and the second isn't used.
        let target = glb.accessor("""
            {"componentType": 5126, "count": 3, "type": "VEC3",
             "sparse": {"count": 1, "indices": {"bufferView": \(sparseIndices), "componentType": 5121}, "values": {"bufferView": \(sparseValues)}}}
            """)
        let unusedTarget = glb.floats("VEC3", [10, 10, 10, 10, 10, 10, 10, 10, 10])
        let data = glb.build("""
            "scenes": [{"nodes": [0]}],
            "nodes": [{"mesh": 0}],
            "meshes": [{
              "primitives": [{"attributes": {"POSITION": \(positions)}, "targets": [{"POSITION": \(target)}, {"POSITION": \(unusedTarget)}]}],
              "weights": [0.5, 0]
            }]
            """)
        let model = try GltfModel(data: data, resources: nil)
        assertPositions(model, 0, [0, 0, 0, 1, 0, 0, 0, 1, 0.5])
    }

    @Test func gltfWithExternalFiles() throws {
        // The geometry is in a data URI, with quantized (normalized) texture coordinates, and the
        // image is in a separate file.
        var bin = Data(Self.floatBytes(Self.triangle))
        for value: UInt16 in [0, 0, 65535, 0, 0, 65535] {
            withUnsafeBytes(of: value.littleEndian) { bin.append(contentsOf: $0) }
        }
        let uri = "data:application/octet-stream;base64," + bin.base64EncodedString()
        let gltf = """
            {
              "asset": {"version": "2.0", "generator": "test"},
              "extensionsRequired": ["KHR_mesh_quantization"],
              "scenes": [{"nodes": [0]}],
              "nodes": [{"mesh": 0}],
              "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "TEXCOORD_0": 1}, "material": 0}]}],
              "materials": [{"pbrMetallicRoughness": {"baseColorTexture": {"index": 0}}}],
              "textures": [{"source": 0}],
              "images": [{"uri": "textures/My%20Image.png"}],
              "buffers": [{"byteLength": 48, "uri": "\(uri)"}],
              "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 36}, {"buffer": 0, "byteOffset": 36, "byteLength": 12}],
              "accessors": [
                {"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
                {"bufferView": 1, "componentType": 5123, "normalized": true, "count": 3, "type": "VEC2"}
              ]
            }
            """
        let resources = MapModelResources(["textures/My Image.png": Data(Self.image)])
        let model = try GltfModel(data: Data(gltf.utf8), resources: resources)
        #expect(resources.requested == ["textures/My Image.png"])
        assertPositions(model, 0, Self.triangle)
        // Flat normals, since the mesh has none.
        for v in 0..<3 {
            assertNormal(model, v, 0, 0, 1)
        }
        #expect(model.parts[0].material.diffuseTexture == Data(Self.image))
        assertTexCoords(model, 0, [0, 1, 1, 1, 0, 0])
    }

    @Test func invalidFiles() throws {
        #expect(throws: (any Error).self) { try GltfModel(data: Data("solid cube\nendsolid\n".utf8), resources: nil) }
        #expect(throws: (any Error).self) { try GltfModel(data: Data("{\"asset\": ".utf8), resources: nil) }
        #expect(throws: (any Error).self) { try GltfModel(data: Data("{\"asset\": {\"version\": \"1.0\"}}".utf8), resources: nil) }

        // Compressed meshes.
        let error = #expect(throws: ModelError.self) {
            try GltfModel(data: Glb().build("""
                "extensionsRequired": ["KHR_draco_mesh_compression"], "scenes": [{"nodes": []}]
                """), resources: nil)
        }
        #expect(error?.message.contains("KHR_draco_mesh_compression") == true)

        // Only points.
        let points = Glb()
        let positions = points.floats("VEC3", Self.triangle)
        let pointsData = points.build("""
            "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
            "meshes": [{"primitives": [{"attributes": {"POSITION": \(positions)}, "mode": 0}]}]
            """)
        #expect(throws: (any Error).self) { try GltfModel(data: pointsData, resources: nil) }

        // An index that's out of range.
        let badIndex = Glb()
        let badPositions = badIndex.floats("VEC3", Self.triangle)
        let indices = badIndex.ints(Self.unsignedShort, "SCALAR", false, [0, 1, 3])
        let badIndexData = badIndex.build("""
            "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
            "meshes": [{"primitives": [{"attributes": {"POSITION": \(badPositions)}, "indices": \(indices)}]}]
            """)
        #expect(throws: (any Error).self) { try GltfModel(data: badIndexData, resources: nil) }

        // An accessor with more elements than its buffer view.
        let badAccessor = Glb()
        let view = badAccessor.view(Self.floatBytes(Self.triangle))
        let accessor = badAccessor.accessor("{\"bufferView\": \(view), \"componentType\": 5126, \"count\": 4, \"type\": \"VEC3\"}")
        let data = badAccessor.build("""
            "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
            "meshes": [{"primitives": [{"attributes": {"POSITION": \(accessor)}}]}]
            """)
        #expect(throws: (any Error).self) { try GltfModel(data: data, resources: nil) }

        // A file that's cut off, and one of glTF 1.0.
        for length in [12, 30, data.count / 2, data.count - 8] {
            #expect(throws: (any Error).self) { try GltfModel(data: data.prefix(length), resources: nil) }
        }
        var version1 = data
        version1[4] = 1
        #expect(throws: (any Error).self) { try GltfModel(data: version1, resources: nil) }
    }

    // MARK: - Helpers

    private static func floatBytes(_ values: [Float]) -> [UInt8] {
        var bytes: [UInt8] = []
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }

    private func assertPositions(_ model: GltfModel, _ firstVertex: Int, _ expected: [Float],
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        for i in expected.indices {
            #expect(abs(model.vertices[firstVertex * 3 + i] - expected[i]) < Self.tolerance, "Coordinate \(i)",
                    sourceLocation: sourceLocation)
        }
    }

    private func assertNormal(_ model: GltfModel, _ vertex: Int, _ x: Float, _ y: Float, _ z: Float,
                              sourceLocation: SourceLocation = #_sourceLocation) {
        let n = model.normals
        #expect(abs(n[vertex * 3] - x) < Self.tolerance, sourceLocation: sourceLocation)
        #expect(abs(n[vertex * 3 + 1] - y) < Self.tolerance, sourceLocation: sourceLocation)
        #expect(abs(n[vertex * 3 + 2] - z) < Self.tolerance, sourceLocation: sourceLocation)
    }

    private func assertTexCoords(_ model: GltfModel, _ firstVertex: Int, _ expected: [Float],
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        guard let texCoords = model.texCoords else {
            Issue.record("No texture coordinates", sourceLocation: sourceLocation)
            return
        }
        for i in expected.indices {
            #expect(abs(texCoords[firstVertex * 2 + i] - expected[i]) < Self.tolerance, "Coordinate \(i)",
                    sourceLocation: sourceLocation)
        }
    }

    private func assertColor(_ model: GltfModel, _ vertex: Int, _ expected: [Float],
                             sourceLocation: SourceLocation = #_sourceLocation) {
        guard let colors = model.colors else {
            Issue.record("No colors", sourceLocation: sourceLocation)
            return
        }
        for c in 0..<4 {
            #expect(abs(colors[vertex * 4 + c] - expected[c]) < Self.tolerance, "Component \(c)", sourceLocation: sourceLocation)
        }
    }

    private func assertIndices(_ model: GltfModel, _ expected: [UInt32], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(model.indices == expected, sourceLocation: sourceLocation)
        #expect(model.indexCount == expected.count, sourceLocation: sourceLocation)
    }

    private func assertClose(_ actual: SIMD3<Float>, _ expected: SIMD3<Float>, _ tolerance: Float = GltfModelTests.tolerance,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        let difference = (0..<3).map { abs(actual[$0] - expected[$0]) }.max() ?? 0
        #expect(difference < tolerance, "\(actual) != \(expected)", sourceLocation: sourceLocation)
    }
}

/// Builds GLB files, whose binary chunk holds the data of the buffer views.
private final class Glb {
    private var bin = Data()
    private var bufferViews: [String] = []
    private var accessors: [String] = []

    private func pad() {
        while bin.count % 4 != 0 {
            bin.append(0)
        }
    }

    /// Adds a buffer view with the given bytes, and returns its index.
    func view(_ bytes: [UInt8]) -> Int {
        pad()
        bufferViews.append("{\"buffer\": 0, \"byteOffset\": \(bin.count), \"byteLength\": \(bytes.count)}")
        bin.append(contentsOf: bytes)
        return bufferViews.count - 1
    }

    func floats(_ type: String, _ values: [Float]) -> Int {
        var bytes: [UInt8] = []
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
        }
        return accessor(view(bytes), 5126, values.count / Self.components(type), type, false)
    }

    func ints(_ componentType: Int, _ type: String, _ normalized: Bool, _ values: [Int]) -> Int {
        let size = componentType == 5121 ? 1 : componentType == 5123 ? 2 : 4
        var bytes: [UInt8] = []
        for value in values {
            switch size {
            case 1: bytes.append(UInt8(truncatingIfNeeded: value))
            case 2: withUnsafeBytes(of: UInt16(truncatingIfNeeded: value).littleEndian) { bytes.append(contentsOf: $0) }
            default: withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).littleEndian) { bytes.append(contentsOf: $0) }
            }
        }
        return accessor(view(bytes), componentType, values.count / Self.components(type), type, normalized)
    }

    func accessor(_ view: Int, _ componentType: Int, _ count: Int, _ type: String, _ normalized: Bool) -> Int {
        accessor("{\"bufferView\": \(view), \"componentType\": \(componentType), \"count\": \(count), \"type\": \"\(type)\""
                 + (normalized ? ", \"normalized\": true" : "") + "}")
    }

    /// Adds an accessor that's given as JSON, and returns its index.
    func accessor(_ json: String) -> Int {
        accessors.append(json)
        return accessors.count - 1
    }

    /// Builds the file, whose JSON has the given members, besides the asset, buffers, buffer views, and accessors.
    func build(_ members: String) -> Data {
        pad()
        let json = "{\"asset\": {\"version\": \"2.0\"}, " + members + ", \"buffers\": [{\"byteLength\": \(bin.count)}], "
            + "\"bufferViews\": [" + bufferViews.joined(separator: ", ") + "], \"accessors\": [" + accessors.joined(separator: ", ") + "]}"
        let jsonBytes = Array(json.utf8)
        // Chunks are padded to multiples of 4 bytes (with spaces, for the JSON).
        let jsonLength = (jsonBytes.count + 3) / 4 * 4
        let length = 12 + 8 + jsonLength + 8 + bin.count
        var out = Data()
        func putInt(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        out.append(contentsOf: Array("glTF".utf8))
        putInt(2)
        putInt(UInt32(length))
        putInt(UInt32(jsonLength))
        putInt(0x4E4F534A)
        out.append(contentsOf: jsonBytes)
        for _ in jsonBytes.count..<jsonLength {
            out.append(UInt8(ascii: " "))
        }
        putInt(UInt32(bin.count))
        putInt(0x004E4942)
        out.append(bin)
        return out
    }

    private static func components(_ type: String) -> Int {
        switch type {
        case "SCALAR": 1
        case "VEC2": 2
        case "VEC3": 3
        case "MAT4": 16
        default: 4
        }
    }
}
