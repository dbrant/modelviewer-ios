//
//  GltfReader.swift
//  ModelViewer
//
//  Reads glTF 2.0 models, in their binary form (GLB), or as JSON (.gltf, whose buffers and images
//  are embedded as data URIs, or are separate files, which are opened from the given resources).
//
//  The meshes of the scene are placed with the transforms of their nodes. Skinned meshes are posed
//  by their joints, and morph targets are applied with their default weights (without animation).
//  Materials are approximated with diffuse colors and textures, and highlights that depend on their
//  roughness (or glossiness). glTF's coordinate system has the Y axis up, and models face +Z.
//
//  Specification: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html
//
//  Copyright 2026 Dmitry Brant. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation

typealias JsonObject = [String: JsonValue]

extension Dictionary where Key == String, Value == JsonValue {
    func map(_ key: String) -> JsonObject? { self[key]?.objectValue }
    func list(_ key: String) -> [JsonValue]? { self[key]?.arrayValue }
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func number(_ key: String) -> Double? { self[key]?.numberValue }

    /// A number that fits in 32 bits, as an Int (truncated).
    func int(_ key: String) -> Int? {
        guard let n = number(key), n >= Double(Int32.min), n <= Double(Int32.max) else { return nil }
        return Int(n)
    }

    /// A number that fits in 64 bits, as an Int (truncated).
    func long(_ key: String) -> Int? {
        guard let n = number(key), n >= -9.2e18, n <= 9.2e18 else { return nil }
        return Int(n)
    }

    /// A list of numbers (with zeros for anything that isn't a number).
    func numbers(_ key: String) -> [Double]? {
        list(key)?.map { $0.numberValue ?? 0 }
    }
}

final class GltfReader {
    /// The vertices and triangles of the scene, and the ranges of triangles with each material.
    struct Mesh {
        /// Position of each vertex (3 floats each).
        let positions: [Float]
        /// Normal of each vertex (3 floats each).
        let normals: [Float]
        /// Texture coordinates of each vertex (2 floats each, with the origin at the bottom left), if any material has a texture.
        let texCoords: [Float]?
        /// Color of each vertex (4 floats each), if any mesh has vertex colors.
        let colors: [Float]?
        /// Vertex indices of the triangles (3 each).
        let indices: [UInt32]
        /// Ranges of indices with their materials, if the scene has any materials.
        let parts: [MeshPart]
    }

    private struct Buffer {
        let data: Data
        let offset: Int
        let length: Int
    }

    private struct BufferView {
        let data: Data
        let start: Int
        let length: Int
        let stride: Int?
    }

    private struct MaterialInfo {
        let material: Material
        /// The set of texture coordinates that the texture uses.
        let texCoord: Int
        /// Affine transform of the texture coordinates (u' = t0 u + t1 v + t2, v' = t3 u + t4 v + t5), if any.
        let uvTransform: [Double]?
    }

    /// The vertices and triangles that have the same material, as they're collected.
    private final class TriangleGroup {
        let info: MaterialInfo?
        var positions: [Float] = []
        var normals: [Float] = []
        var texCoords: [Float] = []
        var colors: [Float] = []
        var indices: [Int] = []
        var vertexCount: Int { positions.count / 3 }

        init(info: MaterialInfo?) {
            self.info = info
        }
    }

    private static let chunkJson: UInt32 = 0x4E4F534A
    private static let chunkBin: UInt32 = 0x004E4942
    private static let maxDepth = 256
    private static let maxValues = 1 << 28

    private static let modeTriangles = 4
    private static let modeTriangleStrip = 5
    private static let modeTriangleFan = 6

    static let typeByte = 5120
    static let typeUnsignedByte = 5121
    static let typeShort = 5122
    static let typeUnsignedShort = 5123
    static let typeUnsignedInt = 5125
    static let typeFloat = 5126
    private static let componentSizes = [typeByte: 1, typeUnsignedByte: 1, typeShort: 2, typeUnsignedShort: 2, typeUnsignedInt: 4, typeFloat: 4]
    private static let indexTypes: Set<Int> = [typeUnsignedByte, typeUnsignedShort, typeUnsignedInt]
    private static let typeComponents = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16]

    /// Extensions that compress meshes, without which they can't be read.
    private static let compressionExtensions = ["KHR_draco_mesh_compression", "EXT_meshopt_compression", "KHR_meshopt_compression"]

    private static let dielectricReflectance = 0.04
    private static let defaultSpecular: Float = 0.2
    private static let defaultShininess: Float = 20

    private let data: Data
    private let resources: ModelResources?

    private var json: JsonObject = [:]
    private var binaryChunk: Buffer?
    private var nodes: [JsonValue] = []
    private var parents: [Int: Int] = [:]
    private var worldTransforms: [Int: [Double]] = [:]
    private var buffers: [Int: Buffer?] = [:]
    private var images: [Int: Data?] = [:]
    private var materials: [Int: MaterialInfo?] = [:]
    private var jointTransforms: [Int: [[Double]?]] = [:]
    private var groups: [Int: TriangleGroup] = [:]
    private var groupOrder: [Int] = []
    private var hasColors = false

    init(data: Data, resources: ModelResources?) {
        self.data = data.rebased
        self.resources = resources
    }

    func read() throws -> Mesh {
        try readContainer()
        let asset = json.map("asset")
        let version = asset?.string("version")
        if asset == nil || !(version?.hasPrefix("2.") ?? false) {
            throw ModelError(version != nil ? "glTF version \(version!) isn't supported." : "Not a valid glTF file.")
        }
        let required = (json.list("extensionsRequired") ?? []).compactMap { $0.stringValue }
        let unsupported = required.filter { Self.compressionExtensions.contains($0) }
        if !unsupported.isEmpty {
            throw ModelError("The model is compressed with \(unsupported.joined(separator: ", ")), which isn't supported.")
        }

        nodes = json.list("nodes") ?? []
        for (i, node) in nodes.enumerated() {
            for child in node.objectValue?.list("children") ?? [] {
                if let c = child.intValue, parents[c] == nil {
                    parents[c] = i
                }
            }
        }
        // The nodes of the default scene, or of the first scene, or (without scenes) all nodes without parents.
        let scenes = json.list("scenes") ?? []
        let sceneIndex = json.int("scene") ?? 0
        let scene = (sceneIndex >= 0 && sceneIndex < scenes.count) ? scenes[sceneIndex].objectValue : nil
        let roots: [Int] = scene?.list("nodes").map { $0.compactMap { $0.intValue } }
            ?? nodes.indices.filter { parents[$0] == nil }
        var visited = Set<Int>()
        // A stack, whose last element is processed next.
        var pending = Array(roots.reversed())
        while let index = pending.popLast() {
            guard index >= 0, index < nodes.count, let node = nodes[index].objectValue else { continue }
            // Each node can only be in the scene once.
            if !visited.insert(index).inserted {
                continue
            }
            try addNode(index, node)
            // The children come next, before the node's siblings.
            let children = (node.list("children") ?? []).compactMap { $0.intValue }
            pending.append(contentsOf: children.reversed())
        }
        return try buildMesh()
    }

    /// Reads the JSON of the file, and its binary chunk, if it's a GLB file.
    private func readContainer() throws {
        let jsonData: Data
        if data.count >= 12 && data[0] == 0x67 && data[1] == 0x6C && data[2] == 0x54 && data[3] == 0x46 { // "glTF"
            let version = Int32(bitPattern: data.uint32LE(at: 4))
            if version != 2 {
                throw ModelError("glTF version \(version) isn't supported.")
            }
            let length = min(Int(data.uint32LE(at: 8)), data.count)
            var json: Data?
            var pos = 12
            while pos + 8 <= length {
                let chunkLength = Int(Int32(bitPattern: data.uint32LE(at: pos)))
                let chunkType = data.uint32LE(at: pos + 4)
                if chunkLength < 0 || chunkLength > length - pos - 8 {
                    throw ModelError("Invalid GLB chunk.")
                }
                if chunkType == Self.chunkJson && json == nil {
                    json = data.subdata(in: (pos + 8)..<(pos + 8 + chunkLength))
                } else if chunkType == Self.chunkBin && binaryChunk == nil {
                    binaryChunk = Buffer(data: data, offset: pos + 8, length: chunkLength)
                }
                pos += 8 + chunkLength
            }
            guard let json else {
                throw ModelError("GLB file has no JSON chunk.")
            }
            jsonData = json
        } else {
            jsonData = data
        }
        guard let object = try JsonParser.parse(jsonData).objectValue else {
            throw ModelError("Not a valid glTF file.")
        }
        json = object
    }

    /// The object at the given index of one of the top-level lists of the file (like "nodes"), if it's there.
    private func element(_ listName: String, _ index: Int) -> JsonObject? {
        guard let list = json.list(listName), index >= 0, index < list.count else { return nil }
        return list[index].objectValue
    }

    private func node(_ index: Int) -> JsonObject? {
        (index >= 0 && index < nodes.count) ? nodes[index].objectValue : nil
    }

    /// Transform of a node to world coordinates (as a column-major 4x4 matrix).
    private func worldTransform(_ index: Int, _ depth: Int = 0) -> [Double] {
        if let cached = worldTransforms[index] {
            return cached
        }
        guard let node = node(index) else {
            return Transforms.identity()
        }
        let local = localTransform(node)
        let world: [Double]
        if let parent = parents[index], depth < Self.maxDepth {
            world = Transforms.multiply(worldTransform(parent, depth + 1), local)
        } else {
            world = local
        }
        worldTransforms[index] = world
        return world
    }

    /// The transform of a node relative to its parent: a matrix, or a translation, rotation (quaternion), and scale.
    private func localTransform(_ node: JsonObject) -> [Double] {
        if let matrix = node.numbers("matrix"), matrix.count == 16 {
            return matrix
        }
        let t = node.numbers("translation").flatMap { $0.count == 3 ? $0 : nil } ?? [0, 0, 0]
        let r = node.numbers("rotation").flatMap { $0.count == 4 ? $0 : nil } ?? [0, 0, 0, 1]
        let s = node.numbers("scale").flatMap { $0.count == 3 ? $0 : nil } ?? [1, 1, 1]
        return Transforms.multiply(Transforms.translation(t),
                                   Transforms.multiply(Transforms.rotation(x: r[0], y: r[1], z: r[2], w: r[3]), Transforms.scaling(s)))
    }

    private func addNode(_ index: Int, _ node: JsonObject) throws {
        guard let meshIndex = node.int("mesh"), let mesh = element("meshes", meshIndex) else { return }
        let skin = node.int("skin").flatMap { element("skins", $0) != nil ? $0 : nil }
        let morphWeights = node.numbers("weights") ?? mesh.numbers("weights") ?? []
        for primitive in mesh.list("primitives") ?? [] {
            if let p = primitive.objectValue {
                try addPrimitive(p, worldTransform(index), skin, morphWeights)
            }
        }
    }

    private func addPrimitive(_ primitive: JsonObject, _ nodeTransform: [Double], _ skin: Int?, _ morphWeights: [Double]) throws {
        // Points and lines aren't shown.
        let mode = primitive.int("mode") ?? Self.modeTriangles
        if mode < Self.modeTriangles || mode > Self.modeTriangleFan {
            return
        }
        guard let attributes = primitive.map("attributes"), let positionIndex = attributes.int("POSITION") else { return }
        let positionAccessor = try Accessor(self, positionIndex)
        let vertexCount = positionAccessor.count
        var positions = try positionAccessor.floats(3)
        var normals: [Float]?
        if let normalIndex = attributes.int("NORMAL") {
            let accessor = try Accessor(self, normalIndex)
            if accessor.count == vertexCount {
                normals = try accessor.floats(3)
            }
        }

        // Morph targets add their displacements, by their weights.
        for (t, target) in (primitive.list("targets") ?? []).enumerated() {
            let weight = t < morphWeights.count ? Float(morphWeights[t]) : 0
            guard weight != 0, let target = target.objectValue else { continue }
            if let index = target.int("POSITION") {
                let accessor = try Accessor(self, index)
                if accessor.count == vertexCount {
                    let offsets = try accessor.floats(3)
                    for i in positions.indices { positions[i] += offsets[i] * weight }
                }
            }
            guard normals != nil else { continue }
            if let index = target.int("NORMAL") {
                let accessor = try Accessor(self, index)
                if accessor.count == vertexCount {
                    let offsets = try accessor.floats(3)
                    for i in normals!.indices { normals![i] += offsets[i] * weight }
                }
            }
        }

        let materialIndex = primitive.int("material") ?? -1
        let info = try materialInfo(materialIndex)
        var texCoords: [Float]?
        if let info, info.material.diffuseTexture != nil, let index = attributes.int("TEXCOORD_\(info.texCoord)") {
            let accessor = try Accessor(self, index)
            if accessor.count == vertexCount {
                texCoords = try accessor.floats(2)
            }
        }
        var colors: [Float]?
        var colorComponents = 0
        if let index = attributes.int("COLOR_0") {
            let accessor = try Accessor(self, index)
            if accessor.count == vertexCount && (3...4).contains(accessor.components) {
                colors = accessor.allFloats()
                colorComponents = accessor.components
            }
        }
        hasColors = hasColors || colors != nil

        // A transform for each vertex of a skinned mesh, or one for all vertices.
        let transforms = try skin.flatMap { try skinTransforms($0, attributes, vertexCount, nodeTransform) } ?? nodeTransform
        let stride = transforms.count > 16 ? 1 : 0
        let transformCount = transforms.count / 16
        var normalMatrices = [Double](repeating: 0, count: transformCount * 9)
        for i in 0..<transformCount {
            Transforms.normalMatrix(transforms, i * 16, &normalMatrices, i * 9)
        }

        let triangles = try triangleIndices(primitive, mode, vertexCount)
        let group: TriangleGroup
        if let existing = groups[materialIndex] {
            group = existing
        } else {
            group = TriangleGroup(info: info)
            groups[materialIndex] = group
            groupOrder.append(materialIndex)
        }
        var position = [Double](repeating: 0, count: 9)
        var normal = [Double](repeating: 0, count: 9)
        let uvTransform = info?.uvTransform

        func addVertex(_ v: Int, _ normalIndex: Int) {
            group.positions.append(Float(position[normalIndex * 3]))
            group.positions.append(Float(position[normalIndex * 3 + 1]))
            group.positions.append(Float(position[normalIndex * 3 + 2]))
            group.normals.append(Float(normal[normalIndex * 3]))
            group.normals.append(Float(normal[normalIndex * 3 + 1]))
            group.normals.append(Float(normal[normalIndex * 3 + 2]))
            if let texCoords {
                var u = Double(texCoords[v * 2])
                var w = Double(texCoords[v * 2 + 1])
                if let m = uvTransform {
                    let tu = m[0] * u + m[1] * w + m[2]
                    w = m[3] * u + m[4] * w + m[5]
                    u = tu
                }
                // glTF's texture coordinates have their origin at the top left.
                group.texCoords.append(Float(u))
                group.texCoords.append(Float(1 - w))
            } else {
                group.texCoords.append(0)
                group.texCoords.append(0)
            }
            if let colors {
                let base = v * colorComponents
                for c in 0..<3 {
                    group.colors.append(Float(Self.linearToSrgb(Double(colors[base + c]))))
                }
                group.colors.append(colorComponents == 4 ? colors[base + 3] : 1)
            } else {
                group.colors.append(contentsOf: [1, 1, 1, 1])
            }
        }

        if let normals {
            let base = group.vertexCount
            group.positions.reserveCapacity(group.positions.count + vertexCount * 3)
            group.normals.reserveCapacity(group.normals.count + vertexCount * 3)
            group.texCoords.reserveCapacity(group.texCoords.count + vertexCount * 2)
            group.colors.reserveCapacity(group.colors.count + vertexCount * 4)
            var n = [Double](repeating: 0, count: 3)
            for v in 0..<vertexCount {
                Transforms.transformPoint(transforms, v * stride * 16, Double(positions[v * 3]), Double(positions[v * 3 + 1]),
                                          Double(positions[v * 3 + 2]), &position, 0)
                for c in 0..<3 {
                    n[c] = Double(normals[v * 3 + c])
                }
                Transforms.transformNormal(normalMatrices, v * stride * 9, n, 0, &normal, 0)
                addVertex(v, 0)
            }
            group.indices.reserveCapacity(group.indices.count + triangles.count)
            for t in 0..<(triangles.count / 3) {
                let a = triangles[t * 3]
                // A transform that mirrors the mesh turns its triangles inside out, unless their corners are reversed.
                let mirrored = Transforms.determinant(transforms, a * stride * 16) < 0
                group.indices.append(base + a)
                group.indices.append(base + triangles[t * 3 + (mirrored ? 2 : 1)])
                group.indices.append(base + triangles[t * 3 + (mirrored ? 1 : 2)])
            }
        } else {
            // Without normals, triangles are flat shaded, so they don't share their vertices.
            var corner = [0, 0, 0]
            for t in 0..<(triangles.count / 3) {
                let mirrored = Transforms.determinant(transforms, triangles[t * 3] * stride * 16) < 0
                corner[0] = triangles[t * 3]
                corner[1] = triangles[t * 3 + (mirrored ? 2 : 1)]
                corner[2] = triangles[t * 3 + (mirrored ? 1 : 2)]
                for c in 0..<3 {
                    let v = corner[c]
                    Transforms.transformPoint(transforms, v * stride * 16, Double(positions[v * 3]), Double(positions[v * 3 + 1]),
                                              Double(positions[v * 3 + 2]), &position, c * 3)
                }
                Transforms.faceNormal(position, &normal)
                for c in 0..<3 {
                    group.indices.append(group.vertexCount)
                    addVertex(corner[c], c)
                }
            }
        }
    }

    /// The vertex indices of the triangles of a primitive, which may be a list, strip, or fan of triangles.
    private func triangleIndices(_ primitive: JsonObject, _ mode: Int, _ vertexCount: Int) throws -> [Int] {
        let indices: [Int]
        if let index = primitive.int("indices") {
            indices = try Accessor(self, index).ints()
        } else {
            indices = Array(0..<vertexCount)
        }
        for i in indices where i < 0 || i >= vertexCount {
            throw ModelError("Invalid vertex index: \(i)")
        }
        let triangleCount = max(indices.count - 2, 0)
        switch mode {
        case Self.modeTriangleStrip:
            return (0..<(triangleCount * 3)).map { i in
                let t = i / 3
                // Every other triangle of a strip is reversed, to keep the same winding.
                let k = i % 3
                return indices[t + ((t % 2 == 1 && k < 2) ? 1 - k : k)]
            }
        case Self.modeTriangleFan:
            return (0..<(triangleCount * 3)).map { i in
                let t = i / 3
                switch i % 3 {
                case 0: return indices[0]
                case 1: return indices[t + 1]
                default: return indices[t + 2]
                }
            }
        default:
            return indices.count % 3 == 0 ? indices : Array(indices.prefix(indices.count / 3 * 3))
        }
    }

    /// The transform of each vertex of a skinned mesh (16 values each), which is the average of the
    /// transforms of its joints, by their weights; or nil if no vertex has any joints.
    private func skinTransforms(_ skin: Int, _ attributes: JsonObject, _ vertexCount: Int, _ nodeTransform: [Double]) throws -> [Double]? {
        let joints: [[Double]?]
        if let cached = jointTransforms[skin] {
            joints = cached
        } else {
            joints = try jointTransforms(element("skins", skin)!)
            jointTransforms[skin] = joints
        }
        var transforms = [Double](repeating: 0, count: vertexCount * 16)
        var weightSums = [Double](repeating: 0, count: vertexCount)
        var set = 0
        while true {
            guard let jointIndex = attributes.int("JOINTS_\(set)"), let weightIndex = attributes.int("WEIGHTS_\(set)") else { break }
            let jointAccessor = try Accessor(self, jointIndex)
            let weightAccessor = try Accessor(self, weightIndex)
            if jointAccessor.count != vertexCount || weightAccessor.count != vertexCount {
                break
            }
            let jointValues = jointAccessor.ints()
            let weightValues = weightAccessor.allFloats()
            let jc = jointAccessor.components
            let wc = weightAccessor.components
            for v in 0..<vertexCount {
                for k in 0..<min(jc, wc) {
                    let weight = Double(weightValues[v * wc + k])
                    let j = jointValues[v * jc + k]
                    guard j >= 0, j < joints.count, let m = joints[j] else { continue }
                    if !(weight > 0) {
                        continue
                    }
                    weightSums[v] += weight
                    for i in 0..<16 {
                        transforms[v * 16 + i] += m[i] * weight
                    }
                }
            }
            set += 1
        }
        if weightSums.allSatisfy({ $0 == 0 }) {
            return nil
        }
        for v in 0..<vertexCount {
            if weightSums[v] > 0 {
                for i in 0..<16 {
                    transforms[v * 16 + i] /= weightSums[v]
                }
            } else {
                transforms.replaceSubrange((v * 16)..<(v * 16 + 16), with: nodeTransform)
            }
        }
        return transforms
    }

    /// The transform of each joint of a skin: its world transform times its inverse bind matrix.
    private func jointTransforms(_ skin: JsonObject) throws -> [[Double]?] {
        let joints = skin.list("joints") ?? []
        var inverseBindMatrices: [Float]?
        var inverseBindCount = 0
        if let index = skin.int("inverseBindMatrices") {
            let accessor = try Accessor(self, index)
            if accessor.components == 16 {
                inverseBindMatrices = accessor.allFloats()
                inverseBindCount = accessor.count
            }
        }
        return joints.enumerated().map { (j, value) -> [Double]? in
            guard let joint = value.intValue, node(joint) != nil else { return nil }
            let inverseBind: [Double]
            if let matrices = inverseBindMatrices, j < inverseBindCount {
                inverseBind = (0..<16).map { Double(matrices[j * 16 + $0]) }
            } else {
                inverseBind = Transforms.identity()
            }
            return Transforms.multiply(worldTransform(joint), inverseBind)
        }
    }

    private func materialInfo(_ index: Int) throws -> MaterialInfo? {
        if let cached = materials[index] {
            return cached
        }
        let info = try element("materials", index).map { try buildMaterial($0) }
        materials[index] = .some(info)
        return info
    }

    private func buildMaterial(_ properties: JsonObject) throws -> MaterialInfo {
        let material = Material(name: properties.string("name") ?? "")
        let extensions = properties.map("extensions")
        let pbr = properties.map("pbrMetallicRoughness")
        // The (archived) specular-glossiness extension is used if it's required, or if the material has nothing else.
        let specularGlossinessRequired = (json.list("extensionsRequired") ?? []).contains { $0.stringValue == "KHR_materials_pbrSpecularGlossiness" }
        let specularGlossiness = extensions?.map("KHR_materials_pbrSpecularGlossiness").flatMap {
            (pbr == nil || specularGlossinessRequired) ? $0 : nil
        }
        let baseColor: [Double]
        let textureInfo: JsonObject?
        // Highlights that are given by a texture (whose values aren't known here) are moderate ones.
        material.specularColor = SIMD3(repeating: Self.defaultSpecular)
        material.shininess = Self.defaultShininess
        if let specularGlossiness {
            baseColor = specularGlossiness.numbers("diffuseFactor").flatMap { $0.count == 4 ? $0 : nil } ?? [1, 1, 1, 1]
            textureInfo = specularGlossiness.map("diffuseTexture")
            if specularGlossiness.map("specularGlossinessTexture") == nil {
                let specular = specularGlossiness.numbers("specularFactor").flatMap { $0.count == 3 ? $0 : nil } ?? [1, 1, 1]
                Self.setHighlight(material, specular, 1 - (specularGlossiness.number("glossinessFactor") ?? 1))
            }
        } else {
            baseColor = pbr?.numbers("baseColorFactor").flatMap { $0.count == 4 ? $0 : nil } ?? [1, 1, 1, 1]
            textureInfo = pbr?.map("baseColorTexture")
            if pbr?.map("metallicRoughnessTexture") == nil {
                // Metals reflect their own color, and other materials reflect about 4% of light, of all colors.
                let metallic = min(max(pbr?.number("metallicFactor") ?? 1, 0), 1)
                let reflectance = (0..<3).map { Self.dielectricReflectance + (baseColor[$0] - Self.dielectricReflectance) * metallic }
                Self.setHighlight(material, reflectance, pbr?.number("roughnessFactor") ?? 1)
            }
        }

        // Colors in glTF are linear, and the app's colors (like those of textures) are sRGB.
        material.diffuseColor = SIMD3(Float(Self.linearToSrgb(baseColor[0])), Float(Self.linearToSrgb(baseColor[1])),
                                      Float(Self.linearToSrgb(baseColor[2])))
        material.opacity = min(max(Float(baseColor[3]), 0), 1)
        switch properties.string("alphaMode") {
        case "BLEND": material.alphaMode = .blend
        case "MASK": material.alphaMode = .mask
        default: material.alphaMode = .opaque
        }
        material.alphaCutoff = Float(properties.number("alphaCutoff") ?? 0.5)
        if properties.map("emissiveTexture") == nil {
            let strength = extensions?.map("KHR_materials_emissive_strength")?.number("emissiveStrength") ?? 1
            if let emissive = properties.numbers("emissiveFactor"), emissive.count == 3 {
                let e = (0..<3).map { Float(Self.linearToSrgb(min(max(emissive[$0] * strength, 0), 1))) }
                material.emissiveColor = SIMD3(e[0], e[1], e[2])
            }
        }
        if extensions?.map("KHR_materials_unlit") != nil {
            material.lighting = .none
        }

        var texCoord = 0
        var uvTransform: [Double]?
        let texture = textureInfo?.int("index").flatMap { element("textures", $0) }
        let imageIndex: Int? = texture.flatMap { texture in
            let textureExtensions = texture.map("extensions")
            // Textures in other formats (like WebP or KTX2) may have a PNG or JPEG image as a fallback.
            return texture.int("source") ?? textureExtensions?.map("EXT_texture_webp")?.int("source")
                ?? textureExtensions?.map("KHR_texture_basisu")?.int("source")
        }
        if let imageIndex, let textureInfo, let image = try image(imageIndex) {
            material.diffuseTexture = image
            let imageElement = element("images", imageIndex)
            let name = (imageElement?.string("name") ?? imageElement?.string("uri")).flatMap { $0.hasPrefix("data:") ? nil : $0 }
            material.diffuseTextureName = name ?? "image \(imageIndex)"
            texCoord = textureInfo.int("texCoord") ?? 0
            if let transform = textureInfo.map("extensions")?.map("KHR_texture_transform") {
                let offset = transform.numbers("offset").flatMap { $0.count == 2 ? $0 : nil } ?? [0, 0]
                let scale = transform.numbers("scale").flatMap { $0.count == 2 ? $0 : nil } ?? [1, 1]
                let angle = transform.number("rotation") ?? 0
                let c = cos(angle)
                let s = sin(angle)
                // Scaled, rotated, and then offset, as in the extension's specification.
                uvTransform = [c * scale[0], s * scale[1], offset[0], -s * scale[0], c * scale[1], offset[1]]
                texCoord = transform.int("texCoord") ?? texCoord
            }
        }
        return MaterialInfo(material: material, texCoord: texCoord, uvTransform: uvTransform)
    }

    /// The encoded image (PNG or JPEG) of an image of the file, which may be in a buffer, or at a URI.
    private func image(_ index: Int) throws -> Data? {
        if let cached = images[index] {
            return cached
        }
        let image = element("images", index)
        var result: Data?
        if let viewIndex = image?.int("bufferView") {
            result = try bufferViewBytes(viewIndex)
        } else if let uri = image?.string("uri") {
            result = readUri(uri)
        }
        images[index] = .some(result)
        return result
    }

    private func bufferViewBytes(_ index: Int) throws -> Data {
        let view = try bufferView(index)
        return view.data.subdata(in: view.start..<(view.start + view.length))
    }

    private func buffer(_ index: Int) throws -> Buffer {
        if buffers[index] == nil {
            let buffer = element("buffers", index)
            var result: Buffer?
            if buffer != nil {
                if let uri = buffer?.string("uri") {
                    result = readUri(uri).map { Buffer(data: $0.rebased, offset: 0, length: $0.count) }
                } else {
                    // The buffer of a GLB file without a URI is its binary chunk.
                    result = binaryChunk
                }
            }
            buffers[index] = .some(result)
        }
        guard let buffer = buffers[index] ?? nil else {
            throw ModelError("Buffer \(index) isn't available.")
        }
        return buffer
    }

    /// Reads the data at a URI, which is either a data URI, or the (relative) path of a separate file.
    private func readUri(_ uri: String) -> Data? {
        if uri.hasPrefix("data:") {
            guard let comma = uri.firstIndex(of: ",") else {
                return nil
            }
            let payload = String(uri[uri.index(after: comma)...])
            if uri[..<comma].hasSuffix(";base64") {
                return Self.decodeBase64(payload)
            }
            return Self.percentDecode(payload)
        }
        let path = String(decoding: Self.percentDecode(uri), as: UTF8.self)
        return resources?.open(path)
    }

    private func buildMesh() throws -> Mesh {
        let orderedGroups = groupOrder.map { groups[$0]! }
        let vertexCount = orderedGroups.reduce(0) { $0 + $1.vertexCount }
        let indexCount = orderedGroups.reduce(0) { $0 + $1.indices.count }
        if indexCount == 0 {
            throw ModelError("No triangles found in model.")
        }
        if vertexCount > Int(UInt32.max) {
            throw ModelError("The model is too large.")
        }
        var positions: [Float] = []
        var normals: [Float] = []
        var texCoords: [Float] = []
        var colors: [Float] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(vertexCount * 3)
        normals.reserveCapacity(vertexCount * 3)
        texCoords.reserveCapacity(vertexCount * 2)
        colors.reserveCapacity(vertexCount * 4)
        indices.reserveCapacity(indexCount)
        var parts: [MeshPart] = []
        let hasMaterials = orderedGroups.contains { $0.info != nil }
        var firstVertex = 0
        for group in orderedGroups {
            positions.append(contentsOf: group.positions)
            normals.append(contentsOf: group.normals)
            texCoords.append(contentsOf: group.texCoords)
            colors.append(contentsOf: group.colors)
            let firstIndex = indices.count
            for i in group.indices {
                indices.append(UInt32(firstVertex + i))
            }
            if hasMaterials {
                parts.append(MeshPart(material: group.info?.material ?? Material(), first: firstIndex, count: group.indices.count))
            }
            firstVertex += group.vertexCount
        }
        let hasTextures = parts.contains { $0.material.diffuseTexture != nil }
        return Mesh(positions: positions, normals: normals, texCoords: hasTextures ? texCoords : nil,
                    colors: hasColors ? colors : nil, indices: indices, parts: parts)
    }

    private func bufferView(_ index: Int) throws -> BufferView {
        guard let view = element("bufferViews", index) else {
            throw ModelError("Invalid buffer view: \(index)")
        }
        let buffer = try buffer(view.int("buffer") ?? -1)
        let offset = view.long("byteOffset") ?? 0
        guard let length = view.long("byteLength") else {
            throw ModelError("Invalid buffer view: \(index)")
        }
        if offset < 0 || length < 0 || offset > buffer.length || length > buffer.length - offset {
            throw ModelError("Buffer view \(index) is out of bounds.")
        }
        let stride = view.int("byteStride").flatMap { $0 > 0 ? $0 : nil }
        return BufferView(data: buffer.data, start: buffer.offset + offset, length: length, stride: stride)
    }

    /// Reads the elements of an accessor: from its buffer view (or zeros, without one), and its
    /// sparse values, which replace some of the elements. Integers that are normalized are converted
    /// to fractions (from 0 to 1, or from -1 to 1 if they're signed).
    private struct Accessor {
        let count: Int
        let components: Int
        private let componentType: Int
        private let componentSize: Int
        private let normalized: Bool
        private var buffer: Data?
        private var start = 0
        private var stride = 0
        private var sparseElements: [Int: Int]?
        private var sparseBuffer: Data?
        private var sparseStart = 0

        init(_ reader: GltfReader, _ index: Int) throws {
            guard let accessor = reader.element("accessors", index) else {
                throw ModelError("Invalid accessor: \(index)")
            }
            guard let count = accessor.int("count"), count >= 0 else {
                throw ModelError("Invalid accessor: \(index)")
            }
            self.count = count
            guard let components = GltfReader.typeComponents[accessor.string("type") ?? ""] else {
                throw ModelError("Invalid accessor type: \(accessor.string("type") ?? "null")")
            }
            self.components = components
            componentType = accessor.int("componentType") ?? 0
            guard let componentSize = GltfReader.componentSizes[componentType] else {
                throw ModelError("Invalid accessor component type: \(componentType)")
            }
            self.componentSize = componentSize
            if case .bool(true) = accessor["normalized"] {
                normalized = true
            } else {
                normalized = false
            }
            let elementSize = components * componentSize
            if count * components > GltfReader.maxValues {
                throw ModelError("Accessor \(index) is too large.")
            }
            if let viewIndex = accessor.int("bufferView") {
                let view = try reader.bufferView(viewIndex)
                stride = view.stride ?? elementSize
                let offset = accessor.long("byteOffset") ?? 0
                if stride < elementSize || offset < 0 || (count > 0 && offset + (count - 1) * stride + elementSize > view.length) {
                    throw ModelError("Accessor \(index) is out of bounds.")
                }
                buffer = view.data
                start = view.start + offset
            }
            if let sparse = accessor.map("sparse") {
                guard let sparseCount = sparse.int("count"), sparseCount >= 0, sparseCount <= count,
                      let sparseIndices = sparse.map("indices"), let values = sparse.map("values") else {
                    throw ModelError("Invalid sparse accessor: \(index)")
                }
                let indexType = sparseIndices.int("componentType") ?? 0
                guard GltfReader.indexTypes.contains(indexType), let indexSize = GltfReader.componentSizes[indexType] else {
                    throw ModelError("Invalid sparse accessor: \(index)")
                }
                let indexView = try reader.bufferView(sparseIndices.int("bufferView") ?? -1)
                let valueView = try reader.bufferView(values.int("bufferView") ?? -1)
                let indexOffset = sparseIndices.long("byteOffset") ?? 0
                let valueOffset = values.long("byteOffset") ?? 0
                if indexOffset < 0 || valueOffset < 0 || indexOffset + sparseCount * indexSize > indexView.length ||
                    valueOffset + sparseCount * elementSize > valueView.length {
                    throw ModelError("Sparse accessor \(index) is out of bounds.")
                }
                var elements: [Int: Int] = [:]
                elements.reserveCapacity(sparseCount)
                indexView.data.withUnsafeBytes { raw in
                    for i in 0..<sparseCount {
                        let element = GltfReader.readInteger(raw, indexView.start + indexOffset + i * indexSize, indexType)
                        if element >= 0 && element < count {
                            elements[element] = i
                        }
                    }
                }
                sparseElements = elements
                sparseBuffer = valueView.data
                sparseStart = valueView.start + valueOffset
            }
        }

        /// All values, with the given number of components per element (which the accessor must have).
        func floats(_ expectedComponents: Int) throws -> [Float] {
            if components != expectedComponents {
                throw ModelError("Accessor has \(components) components instead of \(expectedComponents).")
            }
            return allFloats()
        }

        /// All values (`components` per element), as floats.
        func allFloats() -> [Float] {
            let total = count * components
            var result = [Float](repeating: 0, count: total)
            withRaw { raw, sparseRaw in
                result.withUnsafeMutableBufferPointer { out in
                    for e in 0..<count {
                        for c in 0..<components {
                            out[e * components + c] = float(raw, sparseRaw, e, c)
                        }
                    }
                }
            }
            return result
        }

        /// All values (`components` per element), as integers.
        func ints() -> [Int] {
            let total = count * components
            var result = [Int](repeating: 0, count: total)
            withRaw { raw, sparseRaw in
                result.withUnsafeMutableBufferPointer { out in
                    for e in 0..<count {
                        for c in 0..<components {
                            out[e * components + c] = int(raw, sparseRaw, e, c)
                        }
                    }
                }
            }
            return result
        }

        private func withRaw(_ body: (UnsafeRawBufferPointer?, UnsafeRawBufferPointer?) -> Void) {
            func withSparse(_ raw: UnsafeRawBufferPointer?) {
                if let sparseBuffer {
                    sparseBuffer.withUnsafeBytes { body(raw, $0) }
                } else {
                    body(raw, nil)
                }
            }
            if let buffer {
                buffer.withUnsafeBytes { withSparse($0) }
            } else {
                withSparse(nil)
            }
        }

        /// The buffer and position of a component of an element, or nil if it's zero (without a buffer view).
        @inline(__always)
        private func locate(_ raw: UnsafeRawBufferPointer?, _ sparseRaw: UnsafeRawBufferPointer?,
                            _ element: Int, _ component: Int) -> (UnsafeRawBufferPointer, Int)? {
            if let sparseElements, let sparseRaw, let i = sparseElements[element] {
                return (sparseRaw, sparseStart + (i * components + component) * componentSize)
            }
            guard let raw else { return nil }
            return (raw, start + element * stride + component * componentSize)
        }

        private func float(_ raw: UnsafeRawBufferPointer?, _ sparseRaw: UnsafeRawBufferPointer?, _ element: Int, _ component: Int) -> Float {
            guard let location = locate(raw, sparseRaw, element, component) else { return 0 }
            let (buffer, pos) = location
            if componentType == GltfReader.typeFloat {
                return Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: pos, as: UInt32.self)))
            }
            let value = Float(GltfReader.readInteger(buffer, pos, componentType))
            if !normalized {
                return value
            }
            switch componentType {
            case GltfReader.typeByte: return max(value / 127, -1)
            case GltfReader.typeUnsignedByte: return value / 255
            case GltfReader.typeShort: return max(value / 32767, -1)
            case GltfReader.typeUnsignedShort: return value / 65535
            default: return Float(Double(value) / 4294967295.0)
            }
        }

        private func int(_ raw: UnsafeRawBufferPointer?, _ sparseRaw: UnsafeRawBufferPointer?, _ element: Int, _ component: Int) -> Int {
            guard let location = locate(raw, sparseRaw, element, component) else { return 0 }
            let (buffer, pos) = location
            if componentType == GltfReader.typeFloat {
                let f = Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: pos, as: UInt32.self)))
                return JsonParser.toInt(Double(f))
            }
            // Values that don't fit (which would be invalid indices) become -1.
            let value = GltfReader.readInteger(buffer, pos, componentType)
            return value <= Int(Int32.max) ? value : -1
        }
    }

    @inline(__always)
    private static func readInteger(_ buffer: UnsafeRawBufferPointer, _ pos: Int, _ componentType: Int) -> Int {
        switch componentType {
        case typeByte: return Int(Int8(bitPattern: buffer[pos]))
        case typeUnsignedByte: return Int(buffer[pos])
        case typeShort: return Int(Int16(bitPattern: UInt16(littleEndian: buffer.loadUnaligned(fromByteOffset: pos, as: UInt16.self))))
        case typeUnsignedShort: return Int(UInt16(littleEndian: buffer.loadUnaligned(fromByteOffset: pos, as: UInt16.self)))
        default: return Int(UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: pos, as: UInt32.self)))
        }
    }

    /// Sets the highlight of a material, to approximate a physically based one with the given
    /// reflectance (at normal incidence, in linear RGB) and roughness.
    private static func setHighlight(_ material: Material, _ reflectance: [Double], _ roughness: Double) {
        let r = min(max(roughness, 0.05), 1)
        let shininess = min(max(2 / pow(r, 4) - 2, 1), 256)
        // A sharper highlight is brighter, since it reflects the same amount of light (as in normalized
        // Blinn-Phong), and the highlights of rough materials fade away, since they're spread so widely
        // that they'd only brighten the whole material. The highlight is added to colors that are sRGB,
        // to which a small linear amount adds about the same amount.
        let scale = (shininess + 8) / 8 * (1 - r * r)
        let s = (0..<3).map { Float(min(max(reflectance[$0] * scale, 0), 1)) }
        material.specularColor = SIMD3(s[0], s[1], s[2])
        material.shininess = Float(shininess)
    }

    static func linearToSrgb(_ value: Double) -> Double {
        let v = min(max(value, 0), 1)
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    /// Decodes the percent-encoded characters (like "%20") of a URI.
    static func percentDecode(_ text: String) -> Data {
        let bytes = Array(text.utf8)
        var output = Data(capacity: bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%") && i + 3 <= bytes.count,
               let code = UInt8(String(decoding: bytes[(i + 1)..<(i + 3)], as: UTF8.self), radix: 16) {
                output.append(code)
                i += 3
            } else {
                output.append(bytes[i])
                i += 1
            }
        }
        return output
    }

    /// Decodes Base64, ignoring whitespace, and stopping at padding. Returns nil for any other invalid character.
    static func decodeBase64(_ text: String) -> Data? {
        var output = Data(capacity: text.utf8.count * 3 / 4)
        var buffer: UInt32 = 0
        var bits = 0
        for ch in text.utf8 {
            let value: UInt32
            switch ch {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): value = UInt32(ch - UInt8(ascii: "A"))
            case UInt8(ascii: "a")...UInt8(ascii: "z"): value = UInt32(ch - UInt8(ascii: "a")) + 26
            case UInt8(ascii: "0")...UInt8(ascii: "9"): value = UInt32(ch - UInt8(ascii: "0")) + 52
            case UInt8(ascii: "+"): value = 62
            case UInt8(ascii: "/"): value = 63
            case UInt8(ascii: "="): return output
            default:
                if TextScanner.isSpace(ch) { continue }
                return nil
            }
            buffer = (buffer << 6) | value
            bits += 6
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> UInt32(bits)) & 0xff))
            }
        }
        return output
    }
}
