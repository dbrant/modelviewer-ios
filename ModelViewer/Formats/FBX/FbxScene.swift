//
//  FbxScene.swift
//  ModelViewer
//
//  Interprets an FBX file: finds the meshes of its models, places them with the transforms of the
//  models and their ancestors (in a coordinate system with the Y axis up), and converts their
//  polygons into triangles, with their normals, texture coordinates, and materials. Meshes that are
//  skinned are posed by their bones (with the bones' transforms in the file, without animation).
//
//  Files of version 7 refer to objects by ID, and connect models to their meshes (geometry),
//  materials to models, and textures to materials. Files of version 6 refer to objects by name,
//  have the meshes inside the models, and connect textures to the models, with a texture for each
//  polygon in a layer of the mesh.
//
//  Info on the format: the FBX SDK documentation (https://help.autodesk.com/view/FBX/2020/ENU/),
//  in particular on the transforms of nodes (FbxNode) and on layer elements (FbxLayerElement).
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

final class FbxScene {
    /// The triangles of the scene, with three corners each, and the ranges of triangles with each material.
    struct Mesh {
        let triangleCount: Int
        /// Position of each corner of each triangle (9 floats per triangle).
        let positions: [Float]
        /// Normal of each corner of each triangle (9 floats per triangle).
        let normals: [Float]
        /// Texture coordinates of each corner of each triangle (6 floats per triangle), if any material has a texture.
        let texCoords: [Float]?
        /// Ranges of triangles with their materials, if the scene has any materials.
        let parts: [Part]
    }

    struct Part {
        let material: Material
        let firstTriangle: Int
        let triangleCount: Int
    }

    /// Objects are identified by 64-bit IDs (version 7) or by name (version 6).
    private enum ObjectID: Hashable {
        case id(Int64)
        case name(String)
    }

    private final class SceneObject {
        let id: ObjectID
        let node: FbxNode
        let type: String
        let subclass: String
        let name: String

        init(id: ObjectID, node: FbxNode, type: String, subclass: String, name: String) {
            self.id = id
            self.node = node
            self.type = type
            self.subclass = subclass
            self.name = name
        }
    }

    /// A link from an object to an object that's connected to it, optionally to one of its properties.
    private struct Link {
        let child: SceneObject
        let property: String?
    }

    /// The triangles that have the same material and texture, as they're collected.
    private final class TriangleGroup {
        let material: SceneObject?
        let texture: SceneObject?
        var positions: [Float] = []
        var normals: [Float] = []
        var texCoords: [Float] = []

        init(material: SceneObject?, texture: SceneObject?) {
            self.material = material
            self.texture = texture
        }
    }

    private struct GroupKey: Hashable {
        let material: ObjectIdentifier?
        let texture: ObjectIdentifier?
    }

    private static let maxDepth = 256
    private static let diffusePropertyNames = ["diffuse", "basecolor", "base_color", "albedo"]

    private let document: FbxParser.Document
    private let resources: ModelResources?
    private let isVersion6: Bool
    private var objects: [ObjectID: SceneObject] = [:]
    private var objectOrder: [SceneObject] = []
    private var links: [ObjectID: [Link]] = [:]
    private var parents: [ObjectID: ObjectID] = [:]
    private var worldTransforms: [ObjectID: [Double]] = [:]
    private var groups: [GroupKey: TriangleGroup] = [:]
    private var groupOrder: [TriangleGroup] = []
    private var images: [ObjectIdentifier: Data?] = [:]

    init(document: FbxParser.Document, resources: ModelResources?) {
        self.document = document
        self.resources = resources
        self.isVersion6 = document.version < 7000
    }

    func build() throws -> Mesh {
        guard let objectNodes = document.node("Objects") else {
            throw ModelError("No objects found in FBX file.")
        }
        for node in objectNodes.children {
            // Names are "Name\0\u{1}Class" in binary files, and "Class::Name" in ASCII files.
            let obj: SceneObject
            if isVersion6 {
                guard let id = node.string(0) else { continue }
                obj = SceneObject(id: .name(id), node: node, type: node.name, subclass: node.string(1) ?? "", name: Self.substringAfter(id, "::"))
            } else {
                guard let id = node.id(0) else { continue }
                let fullName = node.string(1) ?? ""
                let beforeNull = fullName.firstIndex(of: "\0").map { String(fullName[..<$0]) } ?? fullName
                obj = SceneObject(id: .id(id), node: node, type: node.name, subclass: node.string(2) ?? "", name: Self.substringAfter(beforeNull, "::"))
            }
            if objects[obj.id] == nil {
                objectOrder.append(obj)
            } else if let index = objectOrder.firstIndex(where: { $0.id == obj.id }) {
                objectOrder[index] = obj
            }
            objects[obj.id] = obj
        }
        for connection in document.node("Connections")?.children ?? [] {
            let childId: ObjectID
            let parentId: ObjectID
            if isVersion6 {
                guard let c = connection.string(1), let p = connection.string(2) else { continue }
                childId = .name(c)
                parentId = .name(p)
            } else {
                guard let c = connection.id(1), let p = connection.id(2) else { continue }
                childId = .id(c)
                parentId = .id(p)
            }
            guard let child = objects[childId] else { continue }
            links[parentId, default: []].append(Link(child: child, property: connection.string(3)))
            // Models are also connected to other objects, such as display layers.
            if connection.string(0) == "OO" && child.type == "Model" && objects[parentId]?.type == "Model" && parents[childId] == nil {
                parents[childId] = parentId
            }
        }

        let settings = document.node("GlobalSettings") ?? objectNodes.child("GlobalSettings")
        let axisConversion = Self.axisConversion(Properties(settings))
        for obj in objectOrder {
            if obj.type != "Model" {
                continue
            }
            let meshes: [SceneObject]
            if isVersion6 {
                meshes = obj.node.child("Vertices") != nil ? [obj] : []
            } else {
                meshes = linked(obj, "Geometry").filter { $0.subclass == "Mesh" }
            }
            if meshes.isEmpty {
                continue
            }
            let properties = Properties(obj.node)
            if properties.number("Show") == 0 || properties.number("Visibility") == 0 {
                continue
            }
            // The geometric transform applies only to the model's own meshes, and not to its children.
            let geometricTransform = Transforms.multiply(Transforms.translation(properties.vector("GeometricTranslation", 0)),
                Transforms.multiply(Transforms.rotation(properties.vector("GeometricRotation", 0), order: 0),
                                    Transforms.scaling(properties.vector("GeometricScaling", 1))))
            let materials = linked(obj, "Material")
            let textures = isVersion6 ? linked(obj, "Texture") : []
            for mesh in meshes {
                let vertexCount = (mesh.node.child("Vertices")?.numbers().count ?? 0) / 3
                let world = worldTransform(obj)
                var transforms = skinTransforms(mesh, vertexCount: vertexCount, meshTransform: world, geometricTransform: geometricTransform)
                    ?? Transforms.multiply(world, geometricTransform)
                for i in 0..<(transforms.count / 16) {
                    let converted = Transforms.multiply(axisConversion, Array(transforms[(i * 16)..<(i * 16 + 16)]))
                    transforms.replaceSubrange((i * 16)..<(i * 16 + 16), with: converted)
                }
                try addMesh(mesh.node, transforms: transforms, materials: materials, textures: textures)
            }
        }
        return try buildMesh()
    }

    private static func substringAfter(_ s: String, _ delimiter: String) -> String {
        if let range = s.range(of: delimiter) {
            return String(s[range.upperBound...])
        }
        return s
    }

    private func linked(_ obj: SceneObject, _ type: String) -> [SceneObject] {
        (links[obj.id] ?? []).map { $0.child }.filter { $0.type == type }
    }

    /// Transform of a model to world coordinates (as a column-major 4x4 matrix).
    private func worldTransform(_ obj: SceneObject, depth: Int = 0) -> [Double] {
        if let cached = worldTransforms[obj.id] {
            return cached
        }
        let local = Self.localTransform(Properties(obj.node))
        var world = local
        if let parentId = parents[obj.id], let parent = objects[parentId], parent.type == "Model", depth < Self.maxDepth {
            world = Transforms.multiply(worldTransform(parent, depth: depth + 1), local)
        }
        worldTransforms[obj.id] = world
        return world
    }

    /// The transform of a model relative to its parent, which is T * Roff * Rp * Rpre * R * Rpost^-1
    /// * Rp^-1 * Soff * Sp * S * Sp^-1 (translation, rotation offset, rotation pivot, pre-rotation,
    /// rotation, post-rotation, scaling offset, scaling pivot, and scaling).
    private static func localTransform(_ p: Properties) -> [Double] {
        let rotationPivot = p.vector("RotationPivot", 0)
        let scalingPivot = p.vector("ScalingPivot", 0)
        let order = p.number("RotationOrder").map { FbxNode.toInt32($0) } ?? 0
        let matrices = [
            Transforms.translation(p.vector("Lcl Translation", 0)),
            Transforms.translation(p.vector("RotationOffset", 0)),
            Transforms.translation(rotationPivot),
            Transforms.rotation(p.vector("PreRotation", 0), order: 0),
            Transforms.rotation(p.vector("Lcl Rotation", 0), order: order),
            Transforms.transpose(Transforms.rotation(p.vector("PostRotation", 0), order: 0)),
            Transforms.translation(rotationPivot.map { -$0 }),
            Transforms.translation(p.vector("ScalingOffset", 0)),
            Transforms.translation(scalingPivot),
            Transforms.scaling(p.vector("Lcl Scaling", 1)),
            Transforms.translation(scalingPivot.map { -$0 })
        ]
        return matrices.dropFirst().reduce(matrices[0]) { Transforms.multiply($0, $1) }
    }

    /// Conversion from the axis system of the file to one where Y is up, Z is the front (where
    /// models face), and X is to the side.
    private static func axisConversion(_ p: Properties) -> [Double] {
        let up = p.number("UpAxis").map { FbxNode.toInt32($0) } ?? 1
        let front = p.number("FrontAxis").map { FbxNode.toInt32($0) } ?? 2
        let coord = p.number("CoordAxis").map { FbxNode.toInt32($0) } ?? 0
        if Set([up, front, coord]) != Set([0, 1, 2]) {
            return Transforms.identity()
        }
        var m = [Double](repeating: 0, count: 16)
        m[coord * 4] = p.number("CoordAxisSign") ?? 1
        m[up * 4 + 1] = p.number("UpAxisSign") ?? 1
        m[front * 4 + 2] = p.number("FrontAxisSign") ?? 1
        m[15] = 1
        return m
    }

    /// The transform of each vertex of a mesh that's skinned (deformed by bones), as a column-major
    /// 4x4 matrix for each vertex, which places the vertex where its bones are posed; or nil if
    /// the mesh isn't skinned. Each cluster of the skin moves its vertices with its bone (link),
    /// from where the bone was when the mesh was bound to it, and vertices with several bones are
    /// moved by the average of their transforms, by their weights.
    ///
    /// In files, the Transform of a cluster is the transform of the mesh relative to the bone (the
    /// TransformLink) when the mesh was bound, so the bone's current transform times the Transform
    /// is where the bone puts the mesh.
    private func skinTransforms(_ mesh: SceneObject, vertexCount: Int, meshTransform: [Double], geometricTransform: [Double]) -> [Double]? {
        let clusters = linked(mesh, "Deformer").filter { $0.subclass == "Skin" }
            .flatMap { linked($0, "Deformer") }.filter { $0.subclass == "Cluster" }
        if clusters.isEmpty || vertexCount == 0 {
            return nil
        }
        var transforms = [Double](repeating: 0, count: vertexCount * 16)
        var weights = [Double](repeating: 0, count: vertexCount)
        for cluster in clusters {
            guard let bone = linked(cluster, "Model").first,
                  let indices = cluster.node.child("Indexes")?.ints(),
                  let clusterWeights = cluster.node.child("Weights")?.numbers() else {
                continue
            }
            // Without the mesh's transform relative to the bone, it's found from the bone's transform when they were bound.
            var relativeTransform: [Double]?
            if let t = cluster.node.child("Transform")?.numbers(), t.count == 16 {
                relativeTransform = t
            } else if let link = cluster.node.child("TransformLink")?.numbers(), link.count == 16, let inverse = Transforms.inverse(link) {
                relativeTransform = Transforms.multiply(inverse, meshTransform)
            }
            guard let relativeTransform else { continue }
            let m = Transforms.multiply(worldTransform(bone), Transforms.multiply(relativeTransform, geometricTransform))
            for i in 0..<min(indices.count, clusterWeights.count) {
                let v = indices[i]
                let weight = clusterWeights[i]
                if v < 0 || v >= vertexCount || !(weight > 0) {
                    continue
                }
                weights[v] += weight
                for k in 0..<16 {
                    transforms[v * 16 + k] += m[k] * weight
                }
            }
        }
        if weights.allSatisfy({ $0 == 0 }) {
            return nil
        }
        // Vertices without bones stay with the mesh.
        let transform = Transforms.multiply(meshTransform, geometricTransform)
        for v in 0..<vertexCount {
            if weights[v] > 0 {
                for k in 0..<16 {
                    transforms[v * 16 + k] /= weights[v]
                }
            } else {
                transforms.replaceSubrange((v * 16)..<(v * 16 + 16), with: transform)
            }
        }
        return transforms
    }

    /// Adds the polygons of a mesh, with the given transforms: one for each vertex (16 values each),
    /// or a single one for all vertices.
    private func addMesh(_ mesh: FbxNode, transforms: [Double], materials: [SceneObject], textures: [SceneObject]) throws {
        guard let vertices = mesh.child("Vertices")?.numbers(),
              let polygonVertices = mesh.child("PolygonVertexIndex")?.ints() else {
            return
        }
        let normalLayer = mesh.child("LayerElementNormal").map { Layer($0, valuesName: "Normals", indexName: "NormalsIndex") }
        let uvLayer = mesh.child("LayerElementUV").map { Layer($0, valuesName: "UV", indexName: "UVIndex") }
        let materialLayer = mesh.child("LayerElementMaterial").map { Layer($0, valuesName: "Materials", indexName: "") }
        let textureLayer = mesh.child("LayerElementTexture").map { Layer($0, valuesName: "TextureId", indexName: "") }

        let transformCount = transforms.count / 16
        // Offsets into the transforms (and normal matrices) are multiplied by a vertex index, or by 0 if there's only one.
        let stride = transformCount > 1 ? 1 : 0
        var normalMatrices = [Double](repeating: 0, count: transformCount * 9)
        var mirroredTransforms = [Bool](repeating: false, count: transformCount)
        for i in 0..<transformCount {
            Transforms.normalMatrix(transforms, i * 16, &normalMatrices, i * 9)
            mirroredTransforms[i] = Transforms.determinant(transforms, i * 16) < 0
        }
        let vertexCount = vertices.count / 3
        let normalValueCount = (normalLayer?.values.count ?? 0) / 3
        let uvValueCount = (uvLayer?.values.count ?? 0) / 2
        var position = [Double](repeating: 0, count: 9)
        var normal = [Double](repeating: 0, count: 9)
        var corners = [0, 0, 0]
        var polygonStart = 0
        var polygon = 0
        for end in 0..<polygonVertices.count {
            if polygonVertices[end] >= 0 {
                continue
            }
            var material: SceneObject?
            if let materialLayer {
                let index = materialLayer.value(polygon: polygon, corner: polygonStart, vertex: 0)
                material = index >= 0 && index < materials.count ? materials[index] : nil
            } else {
                material = materials.first
            }
            let texture: SceneObject?
            if isVersion6 {
                if let textureLayer {
                    let index = textureLayer.value(polygon: polygon, corner: polygonStart, vertex: 0)
                    texture = index >= 0 && index < textures.count ? textures[index] : nil
                } else {
                    texture = nil
                }
            } else {
                texture = material.flatMap { diffuseTexture($0) }
            }
            let key = GroupKey(material: material.map { ObjectIdentifier($0) }, texture: texture.map { ObjectIdentifier($0) })
            let group: TriangleGroup
            if let existing = groups[key] {
                group = existing
            } else {
                group = TriangleGroup(material: material, texture: texture)
                groups[key] = group
                groupOrder.append(group)
            }
            // A transform that mirrors the mesh turns its polygons inside out, unless their corners are reversed.
            let firstVertex = Self.vertexIndex(polygonVertices[polygonStart])
            let mirrorIndex = firstVertex * stride
            let mirrored = mirrorIndex >= 0 && mirrorIndex < mirroredTransforms.count ? mirroredTransforms[mirrorIndex] : false
            // Polygons are split into a fan of triangles around their first corner.
            var k = polygonStart + 1
            while k < end {
                corners[0] = polygonStart
                corners[1] = mirrored ? k + 1 : k
                corners[2] = mirrored ? k : k + 1
                var missingNormal = false
                for c in 0..<3 {
                    let corner = corners[c]
                    let v = Self.vertexIndex(polygonVertices[corner])
                    if v >= vertexCount {
                        throw ModelError("Invalid vertex index: \(v)")
                    }
                    Transforms.transformPoint(transforms, v * stride * 16, vertices[v * 3], vertices[v * 3 + 1], vertices[v * 3 + 2], &position, c * 3)
                    let n = normalLayer?.index(polygon: polygon, corner: corner, vertex: v) ?? -1
                    if let normalLayer, n >= 0 && n < normalValueCount {
                        Transforms.transformNormal(normalMatrices, v * stride * 9, normalLayer.values, n * 3, &normal, c * 3)
                    } else {
                        missingNormal = true
                    }
                    let uv = uvLayer?.index(polygon: polygon, corner: corner, vertex: v) ?? -1
                    if let uvLayer, uv >= 0 && uv < uvValueCount {
                        group.texCoords.append(Float(uvLayer.values[uv * 2]))
                        group.texCoords.append(Float(uvLayer.values[uv * 2 + 1]))
                    } else {
                        group.texCoords.append(0)
                        group.texCoords.append(0)
                    }
                }
                if missingNormal || normal.contains(where: { $0.isNaN }) {
                    Transforms.faceNormal(position, &normal)
                }
                for i in 0..<9 {
                    group.positions.append(Float(position[i]))
                    group.normals.append(Float(normal[i]))
                }
                k += 1
            }
            polygonStart = end + 1
            polygon += 1
        }
    }

    @inline(__always)
    private static func vertexIndex(_ i: Int) -> Int {
        i < 0 ? ~i : i
    }

    private func buildMesh() throws -> Mesh {
        let triangleCount = groupOrder.reduce(0) { $0 + $1.positions.count / 9 }
        if triangleCount == 0 {
            throw ModelError("No meshes found in FBX file.")
        }
        var positions: [Float] = []
        var normals: [Float] = []
        var texCoords: [Float] = []
        positions.reserveCapacity(triangleCount * 9)
        normals.reserveCapacity(triangleCount * 9)
        texCoords.reserveCapacity(triangleCount * 6)
        var parts: [Part] = []
        let hasMaterials = groupOrder.contains { $0.material != nil || $0.texture != nil }
        var hasTextures = false
        var first = 0
        for group in groupOrder {
            let count = group.positions.count / 9
            positions.append(contentsOf: group.positions)
            normals.append(contentsOf: group.normals)
            texCoords.append(contentsOf: group.texCoords)
            if hasMaterials {
                let material = material(group.material, group.texture)
                hasTextures = hasTextures || material.diffuseTexture != nil
                parts.append(Part(material: material, firstTriangle: first, triangleCount: count))
            }
            first += count
        }
        return Mesh(triangleCount: triangleCount, positions: positions, normals: normals,
                    texCoords: hasTextures ? texCoords : nil, parts: parts)
    }

    private func material(_ obj: SceneObject?, _ textureObj: SceneObject?) -> Material {
        let material = Material(name: obj?.name ?? "")
        if let obj {
            let p = Properties(obj.node)
            let diffuse = p.vector("DiffuseColor") ?? p.vector("Diffuse") ?? [0.8, 0.8, 0.8]
            let diffuseFactor = p.number("DiffuseFactor") ?? 1
            material.diffuseColor = SIMD3(Float(diffuse[0] * diffuseFactor), Float(diffuse[1] * diffuseFactor), Float(diffuse[2] * diffuseFactor))
            if let specular = p.vector("SpecularColor") ?? p.vector("Specular") {
                let factor = p.number("SpecularFactor") ?? 1
                material.specularColor = SIMD3(Float(specular[0] * factor), Float(specular[1] * factor), Float(specular[2] * factor))
            }
            if let shininess = p.number("ShininessExponent") ?? p.number("Shininess") {
                material.shininess = Float(shininess)
            }
            if let emissive = p.vector("EmissiveColor") ?? p.vector("Emissive") {
                let factor = p.number("EmissiveFactor") ?? 1
                material.emissiveColor = SIMD3(Float(emissive[0] * factor), Float(emissive[1] * factor), Float(emissive[2] * factor))
            }
            if let opacity = p.number("Opacity") {
                material.opacity = min(max(Float(opacity), 0), 1)
            }
        }
        if let textureObj, let texture = image(textureObj) {
            // The texture is the diffuse color.
            material.diffuseColor = SIMD3(1, 1, 1)
            material.diffuseTexture = texture
            material.diffuseTextureName = textureObj.name
        }
        return material
    }

    /// The texture that gives a material its diffuse color, if it has one.
    private func diffuseTexture(_ material: SceneObject) -> SceneObject? {
        let textures = (links[material.id] ?? []).filter { $0.child.type == "Texture" || $0.child.type == "LayeredTexture" }
        let link = textures.first { $0.property == "DiffuseColor" }
            ?? textures.first { link in
                let property = (link.property ?? "").lowercased()
                return Self.diffusePropertyNames.contains { property.contains($0) }
            }
        guard let link else {
            return nil
        }
        // A layered texture combines several textures, of which the first is used.
        return link.child.type == "LayeredTexture" ? linked(link.child, "Texture").first : link.child
    }

    /// The image of a texture, which may be embedded in the file (in the texture or its video), or in a separate file.
    private func image(_ texture: SceneObject) -> Data? {
        // Textures that aren't found are remembered too, so that they're only looked for once.
        let key = ObjectIdentifier(texture)
        if let cached = images[key] {
            return cached
        }
        var result: Data?
        for obj in [texture] + linked(texture, "Video") {
            if let content = Self.content(obj.node) {
                result = content
                break
            }
        }
        if result == nil {
            result = openFile(texture.node)
        }
        images[key] = .some(result)
        return result
    }

    private static func content(_ node: FbxNode) -> Data? {
        guard let content = node.child("Content") else {
            return nil
        }
        for property in content.properties {
            if case .bytes(let data) = property, !data.isEmpty {
                return data
            }
        }
        // In ASCII files, the content is encoded in Base64, possibly in several strings.
        let encoded = content.properties.compactMap { value -> String? in
            if case .string(let s) = value { return s }
            return nil
        }.joined()
        return encoded.isEmpty ? nil : decodeBase64(encoded)
    }

    private func openFile(_ node: FbxNode) -> Data? {
        let path = (node.child("RelativeFilename") ?? node.child("FileName") ?? node.child("Filename"))?.string(0)
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return resources?.open(path)
    }

    private static let base64Alphabet: [UInt8] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    private static let base64Values: [Int8] = {
        var table = [Int8](repeating: -1, count: 256)
        for (i, c) in base64Alphabet.enumerated() {
            table[Int(c)] = Int8(i)
        }
        return table
    }()

    /// Decodes Base64, ignoring whitespace and stopping at padding; returns nil for other characters.
    static func decodeBase64(_ text: String) -> Data? {
        var output = Data()
        output.reserveCapacity(text.utf8.count * 3 / 4)
        var buffer = 0
        var bits = 0
        for ch in text.utf8 {
            if ch == UInt8(ascii: "=") {
                break
            }
            let value = base64Values[Int(ch)]
            if value < 0 {
                if TextScanner.isSpace(ch) {
                    continue
                }
                return nil
            }
            buffer = ((buffer << 6) | Int(value)) & 0xffffff
            bits += 6
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> bits) & 0xff))
            }
        }
        return output
    }

    /// The properties of an object: its Properties70 node (or Properties60, in version 6).
    private struct Properties {
        private var values: [String: [Double]] = [:]

        init(_ node: FbxNode?) {
            // The values of a property follow its name, type, label (only in Properties70), and flags.
            for property in node?.child("Properties70")?.children("P") ?? [] {
                add(property, start: 4)
            }
            for property in node?.child("Properties60")?.children("Property") ?? [] {
                add(property, start: 3)
            }
        }

        private mutating func add(_ property: FbxNode, start: Int) {
            guard let name = property.string(0) else { return }
            values[name] = start < property.properties.count ? (start..<property.properties.count).compactMap { property.number($0) } : []
        }

        func number(_ name: String) -> Double? {
            values[name]?.first
        }

        func vector(_ name: String) -> [Double]? {
            guard let v = values[name], v.count >= 3 else { return nil }
            return [v[0], v[1], v[2]]
        }

        func vector(_ name: String, _ defaultValue: Double) -> [Double] {
            vector(name) ?? [defaultValue, defaultValue, defaultValue]
        }
    }

    /// A layer of a mesh, which gives a value for each polygon corner, vertex, or polygon, or one for all of them.
    private struct Layer {
        private enum Mapping {
            case byPolygonVertex, byVertex, byPolygon, allSame, unknown
        }

        private let mapping: Mapping
        let values: [Double]
        private let indices: [Int]?

        init(_ node: FbxNode, valuesName: String, indexName: String) {
            switch node.child("MappingInformationType")?.string(0) {
            case "ByPolygonVertex": mapping = .byPolygonVertex
            case "ByVertice", "ByVertex", "ByControlPoint": mapping = .byVertex
            case "ByPolygon": mapping = .byPolygon
            case "AllSame": mapping = .allSame
            default: mapping = .unknown
            }
            values = node.child(valuesName)?.numbers() ?? []
            let reference = node.child("ReferenceInformationType")?.string(0)
            if reference == "IndexToDirect" || reference == "Index", let indexNode = node.child(indexName) {
                indices = indexNode.ints()
            } else {
                indices = nil
            }
        }

        /// The index of the value for a polygon corner (which is also the index of the corner's vertex in the polygon list).
        func index(polygon: Int, corner: Int, vertex: Int) -> Int {
            let i: Int
            switch mapping {
            case .byPolygonVertex: i = corner
            case .byVertex: i = vertex
            case .byPolygon: i = polygon
            case .allSame: i = 0
            case .unknown: return -1
            }
            if let indices {
                return i >= 0 && i < indices.count ? indices[i] : -1
            }
            return i
        }

        /// The value for a polygon corner, as an integer (for layers that give indices of materials or textures).
        func value(polygon: Int, corner: Int, vertex: Int) -> Int {
            let i = index(polygon: polygon, corner: corner, vertex: vertex)
            return i >= 0 && i < values.count ? FbxNode.toInt32(values[i]) : -1
        }
    }
}
