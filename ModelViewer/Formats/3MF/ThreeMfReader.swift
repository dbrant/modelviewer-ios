//
//  ThreeMfReader.swift
//  ModelViewer
//
//  Reader for 3MF (3D Manufacturing Format) files, which are ZIP archives that contain XML model
//  parts. Reads the meshes of the objects in the build, placed with the transforms of the build
//  items and of the components of objects (which may be in other model parts, as in the Production
//  extension), and their colors and textures (from the Materials and Properties extension).
//
//  Info on the format: https://3mf.io/specification/ (the core specification, and the Materials and
//  Properties, and Production extensions).
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

final class ThreeMfReader {
    /// The triangles of the build, in world coordinates, with three corners each. Triangles with
    /// the same texture (or with none) are consecutive, as described by the `parts`.
    struct Mesh {
        let triangleCount: Int
        /// Position of each corner of each triangle (9 floats per triangle).
        let positions: [Float]
        /// RGBA color of each corner of each triangle (12 floats per triangle), if any triangle has a color.
        let colors: [Float]?
        /// Texture coordinates of each corner of each triangle (6 floats per triangle), if any triangle has a texture.
        let texCoords: [Float]?
        let parts: [Part]
    }

    /// A range of consecutive triangles that have the same texture, or none.
    struct Part {
        let firstTriangle: Int
        let triangleCount: Int
        let texture: Data?
        let textureName: String?
    }

    /// The resources and build of a model part of the package.
    fileprivate final class ModelPart {
        var objects: [Int: ModelObject] = [:]
        /// Base materials and color groups (with RGBA colors), and texture coordinate groups, by resource ID.
        var propertyGroups: [Int: PropertyGroup] = [:]
        /// Paths of textures, by resource ID.
        var texturePaths: [Int: String] = [:]
        var buildItems: [Placement] = []
    }

    fileprivate final class ModelObject {
        let defaultPid: Int
        let defaultPindex: Int
        var vertices: [Float] = []
        /// Seven ints per triangle: the indices of its vertices, its property group (or -1), and the property of each corner (or -1).
        var triangles: [Int] = []
        var components: [Placement] = []

        init(defaultPid: Int, defaultPindex: Int) {
            self.defaultPid = defaultPid
            self.defaultPindex = defaultPindex
        }
    }

    /// A build item or component: an object, which may be in another model part, and how it's placed.
    fileprivate struct Placement {
        let objectId: Int
        let transform: [Double]
        let path: String?
    }

    fileprivate final class PropertyGroup {
        var colors: [Float]?
        var texCoords: [Float]?
        let textureId: Int

        init(colors: [Float]?, texCoords: [Float]?, textureId: Int) {
            self.colors = colors
            self.texCoords = texCoords
            self.textureId = textureId
        }
    }

    /// The triangles of the build that have the same texture, as they're collected.
    private final class TriangleGroup {
        let texturePath: String?
        var positions: [Float] = []
        var colors: [Float] = []
        var texCoords: [Float] = []

        init(texturePath: String?) {
            self.texturePath = texturePath
        }
    }

    fileprivate static let modelRelationshipType = "http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"
    private static let rootRelationshipsPath = "_rels/.rels"
    private static let defaultRootPath = "3d/3dmodel.model"
    private static let maxComponentDepth = 32
    fileprivate static let identity: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]

    /// Color of triangles without one, in a model that has colors.
    private static let defaultColor: [Float] = [0.8, 0.8, 0.8, 1]

    private let data: Data
    private var zip: ZipArchive!
    private var modelParts: [String: ModelPart] = [:]
    private var textures: [String: Data?] = [:]
    /// Groups of triangles by texture path (with "" for none), in the order in which they're first used.
    private var triangleGroups: [String: TriangleGroup] = [:]
    private var triangleGroupOrder: [TriangleGroup] = []
    private var hasColors = false

    init(data: Data) {
        self.data = data
    }

    func read() throws -> Mesh {
        do {
            zip = try ZipArchive(data: data)
        } catch {
            throw ModelError("Not a valid 3MF file.")
        }
        return try readPackage()
    }

    private func readPackage() throws -> Mesh {
        var rootPath = Self.defaultRootPath
        if let rels = try zip.read(Self.rootRelationshipsPath), let path = try Self.readRootRelationships(rels) {
            rootPath = path
        }
        if !zip.contains(rootPath) {
            throw ModelError("No 3D model found in file.")
        }
        let root = try modelPart(rootPath)
        for item in root.buildItems {
            try addObject(try item.path.map { try modelPart($0) } ?? root, item.objectId, item.transform, 0)
        }
        return buildMesh()
    }

    /// Returns the model part with the given path, which is parsed the first time it's needed.
    private func modelPart(_ path: String) throws -> ModelPart {
        let normalized = ZipArchive.normalizePath(path)
        if let part = modelParts[normalized] {
            return part
        }
        guard let contents = try zip.read(normalized) else {
            throw ModelError("Missing model part: \(path)")
        }
        let part = try Self.parseModel(contents)
        modelParts[normalized] = part
        return part
    }

    private func texture(_ path: String) -> Data? {
        if let cached = textures[path] {
            return cached
        }
        let contents = try? zip.read(path)
        textures[path] = .some(contents)
        return contents
    }

    /// Returns the path of the model part that holds the build, from the package's relationships.
    private static func readRootRelationships(_ contents: Data) throws -> String? {
        let handler = RelationshipsHandler()
        try parse(contents, handler)
        return handler.rootPath
    }

    private static func parseModel(_ contents: Data) throws -> ModelPart {
        let handler = ModelHandler()
        try parse(contents, handler)
        return handler.part
    }

    private static func parse(_ contents: Data, _ handler: PackageHandler) throws {
        let parser = XMLParser(data: contents)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = handler
        let ok = parser.parse()
        if let error = handler.error {
            throw ModelError("Invalid 3MF model: \(error.message)")
        }
        if !ok {
            let message = parser.parserError?.localizedDescription ?? "XML error"
            throw ModelError("Invalid 3MF model: \(message)")
        }
    }

    /// Adds the triangles of an object, and of its components, to the mesh, placed with the given
    /// transform (a 4x3 affine matrix applied to row vectors, as in 3MF).
    private func addObject(_ part: ModelPart, _ objectId: Int, _ transform: [Double], _ depth: Int) throws {
        if depth > Self.maxComponentDepth {
            throw ModelError("Components are nested too deeply.")
        }
        guard let obj = part.objects[objectId] else {
            throw ModelError("Missing object: \(objectId)")
        }
        try addMesh(part, obj, transform)
        for component in obj.components {
            try addObject(try component.path.map { try modelPart($0) } ?? part, component.objectId,
                          Self.multiply(component.transform, transform), depth + 1)
        }
    }

    private func addMesh(_ part: ModelPart, _ obj: ModelObject, _ m: [Double]) throws {
        let vertexCount = obj.vertices.count / 3
        let v = obj.vertices
        var world = [Float](repeating: 0, count: vertexCount * 3)
        for i in 0..<vertexCount {
            let x = Double(v[i * 3])
            let y = Double(v[i * 3 + 1])
            let z = Double(v[i * 3 + 2])
            world[i * 3] = Float(x * m[0] + y * m[3] + z * m[6] + m[9])
            world[i * 3 + 1] = Float(x * m[1] + y * m[4] + z * m[7] + m[10])
            world[i * 3 + 2] = Float(x * m[2] + y * m[5] + z * m[8] + m[11])
        }
        // A transform that mirrors the object turns its triangles inside out, unless their corners are reversed.
        let corners = Self.determinant(m) < 0 ? [0, 2, 1] : [0, 1, 2]
        let t = obj.triangles
        var properties = [0, 0, 0]
        var color: [Float] = [0, 0, 0, 0]
        let stride = 7
        for i in 0..<(t.count / stride) {
            let base = i * stride
            // A triangle without its own properties has the object's, at every corner.
            var pid = t[base + 3]
            if pid < 0 {
                pid = obj.defaultPid
                properties = [obj.defaultPindex, obj.defaultPindex, obj.defaultPindex]
            } else {
                let p1 = t[base + 4] >= 0 ? t[base + 4] : obj.defaultPindex
                properties[0] = p1
                properties[1] = t[base + 5] >= 0 ? t[base + 5] : p1
                properties[2] = t[base + 6] >= 0 ? t[base + 6] : p1
            }
            let group = part.propertyGroups[pid]
            var texturePath: String?
            if let group, group.texCoords != nil {
                texturePath = part.texturePaths[group.textureId]
            }
            let key = texturePath ?? ""
            let triangles: TriangleGroup
            if let existing = triangleGroups[key] {
                triangles = existing
            } else {
                triangles = TriangleGroup(texturePath: texturePath)
                triangleGroups[key] = triangles
                triangleGroupOrder.append(triangles)
            }
            for c in corners {
                let vertex = t[base + c]
                if vertex < 0 || vertex >= vertexCount {
                    throw ModelError("Invalid vertex index: \(vertex)")
                }
                triangles.positions.append(world[vertex * 3])
                triangles.positions.append(world[vertex * 3 + 1])
                triangles.positions.append(world[vertex * 3 + 2])

                let p = properties[c]
                if let colors = group?.colors, p >= 0, p < colors.count / 4 {
                    color[0] = colors[p * 4]
                    color[1] = colors[p * 4 + 1]
                    color[2] = colors[p * 4 + 2]
                    color[3] = colors[p * 4 + 3]
                    hasColors = true
                } else if texturePath != nil {
                    color = [1, 1, 1, 1]
                } else {
                    color = Self.defaultColor
                }
                triangles.colors.append(contentsOf: color)

                if texturePath != nil, let texCoords = group?.texCoords, p >= 0, p < texCoords.count / 2 {
                    triangles.texCoords.append(texCoords[p * 2])
                    triangles.texCoords.append(texCoords[p * 2 + 1])
                } else {
                    triangles.texCoords.append(0)
                    triangles.texCoords.append(0)
                }
            }
        }
    }

    private func buildMesh() -> Mesh {
        // Triangles without a texture come first, followed by those of each texture (a stable sort).
        let groups = triangleGroupOrder.filter { $0.texturePath == nil } + triangleGroupOrder.filter { $0.texturePath != nil }
        let triangleCount = groups.reduce(0) { $0 + $1.positions.count / 9 }
        var positions: [Float] = []
        var colors: [Float] = []
        var texCoords: [Float] = []
        positions.reserveCapacity(triangleCount * 9)
        colors.reserveCapacity(triangleCount * 12)
        texCoords.reserveCapacity(triangleCount * 6)
        var parts: [Part] = []
        var first = 0
        for group in groups {
            let count = group.positions.count / 9
            positions.append(contentsOf: group.positions)
            colors.append(contentsOf: group.colors)
            texCoords.append(contentsOf: group.texCoords)
            parts.append(Part(firstTriangle: first, triangleCount: count,
                              texture: group.texturePath.flatMap { texture($0) }, textureName: group.texturePath))
            first += count
        }
        let hasTextures = parts.contains { $0.texture != nil }
        return Mesh(triangleCount: triangleCount, positions: positions, colors: hasColors ? colors : nil,
                    texCoords: hasTextures ? texCoords : nil, parts: parts)
    }

    /// Product of two 4x3 affine matrices applied to row vectors: the transform `a` followed by `b`.
    private static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var result = [Double](repeating: 0, count: 12)
        for row in 0..<4 {
            for col in 0..<3 {
                var sum = row == 3 ? b[9 + col] : 0
                for k in 0..<3 {
                    sum += a[row * 3 + k] * b[k * 3 + col]
                }
                result[row * 3 + col] = sum
            }
        }
        return result
    }

    private static func determinant(_ m: [Double]) -> Double {
        m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6])
    }
}

// MARK: - XML handlers

/// Handler for the XML documents of a package, which records the first error (and stops parsing there).
private class PackageHandler: NSObject, XMLParserDelegate {
    var error: ModelError?

    func fail(_ parser: XMLParser, _ message: String) {
        if error == nil {
            error = ModelError(message)
        }
        parser.abortParsing()
    }
}

private final class RelationshipsHandler: PackageHandler {
    var rootPath: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "Relationship" && attributeDict["Type"] == ThreeMfReader.modelRelationshipType {
            if let target = attributeDict["Target"] {
                rootPath = ZipArchive.normalizePath(target)
            }
        }
    }
}

private final class ModelHandler: PackageHandler {
    let part = ThreeMfReader.ModelPart()
    private var obj: ThreeMfReader.ModelObject?
    private var group: ThreeMfReader.PropertyGroup?
    // Other extensions have elements with the same names, elsewhere.
    private var inMesh = false
    private var inBuild = false

    private struct AttributeError: Error {
        let message: String
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        do {
            try startElement(elementName, a)
        } catch let e as AttributeError {
            fail(parser, e.message)
        } catch {
            fail(parser, "\(error)")
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "object": obj = nil
        case "mesh": inMesh = false
        case "build": inBuild = false
        case "basematerials", "colorgroup", "texture2dgroup": group = nil
        default: break
        }
    }

    private func startElement(_ name: String, _ a: [String: String]) throws {
        switch name {
        case "object":
            let o = ThreeMfReader.ModelObject(defaultPid: try int(a, "pid", -1), defaultPindex: try int(a, "pindex", 0))
            part.objects[try int(a, "id")] = o
            obj = o
        case "mesh":
            inMesh = obj != nil
        case "vertex":
            if inMesh, let obj {
                obj.vertices.append(try float(a, "x"))
                obj.vertices.append(try float(a, "y"))
                obj.vertices.append(try float(a, "z"))
            }
        case "triangle":
            if inMesh, let obj {
                obj.triangles.append(try int(a, "v1"))
                obj.triangles.append(try int(a, "v2"))
                obj.triangles.append(try int(a, "v3"))
                obj.triangles.append(try int(a, "pid", -1))
                obj.triangles.append(try int(a, "p1", -1))
                obj.triangles.append(try int(a, "p2", -1))
                obj.triangles.append(try int(a, "p3", -1))
            }
        case "component":
            if let obj {
                obj.components.append(try placement(a))
            }
        case "build":
            inBuild = true
        case "item":
            if inBuild {
                part.buildItems.append(try placement(a))
            }
        case "basematerials", "colorgroup":
            let g = ThreeMfReader.PropertyGroup(colors: [], texCoords: nil, textureId: -1)
            part.propertyGroups[try int(a, "id")] = g
            group = g
        case "base":
            if let group, group.colors != nil {
                Self.addColor(&group.colors!, a["displaycolor"])
            }
        case "color":
            if let group, group.colors != nil {
                Self.addColor(&group.colors!, a["color"])
            }
        case "texture2d":
            if let path = a["path"] {
                part.texturePaths[try int(a, "id")] = ZipArchive.normalizePath(path)
            }
        case "texture2dgroup":
            let g = ThreeMfReader.PropertyGroup(colors: nil, texCoords: [], textureId: try int(a, "texid"))
            part.propertyGroups[try int(a, "id")] = g
            group = g
        case "tex2coord":
            if let group, group.texCoords != nil {
                group.texCoords!.append(try float(a, "u"))
                group.texCoords!.append(try float(a, "v"))
            }
        default:
            break
        }
    }

    private func placement(_ a: [String: String]) throws -> ThreeMfReader.Placement {
        // The path of the Production extension, with whatever prefix its namespace has.
        var path = a["p:path"]
        if path == nil {
            for (key, value) in a where key.hasSuffix(":path") {
                path = value
                break
            }
        }
        let transform = try a["transform"].map { try Self.parseTransform($0) } ?? ThreeMfReader.identity
        return ThreeMfReader.Placement(objectId: try int(a, "objectid"), transform: transform, path: path)
    }

    private func int(_ a: [String: String], _ name: String, _ defaultValue: Int? = nil) throws -> Int {
        guard let value = a[name] else {
            if let defaultValue {
                return defaultValue
            }
            throw AttributeError(message: "Missing attribute: \(name)")
        }
        if let v = Int(value) ?? Int(value.trimmingCharacters(in: .whitespaces)) {
            return v
        }
        throw AttributeError(message: "Invalid \(name): \(value)")
    }

    private func float(_ a: [String: String], _ name: String) throws -> Float {
        guard let value = a[name] else {
            throw AttributeError(message: "Missing attribute: \(name)")
        }
        if let v = Float(value) ?? Float(value.trimmingCharacters(in: .whitespaces)) {
            return v
        }
        throw AttributeError(message: "Invalid \(name): \(value)")
    }

    /// Adds a color given as #RRGGBB or #RRGGBBAA (in sRGB), or the default color if it's invalid.
    private static func addColor(_ colors: inout [Float], _ value: String?) {
        var hex = Substring(value?.trimmingCharacters(in: .whitespaces) ?? "")
        if hex.hasPrefix("#") {
            hex = hex.dropFirst()
        }
        guard hex.count == 6 || hex.count == 8, let rgba = UInt64(hex, radix: 16) else {
            colors.append(contentsOf: [0.8, 0.8, 0.8, 1])
            return
        }
        let shift: UInt64 = hex.count == 8 ? 8 : 0
        colors.append(Float((rgba >> (16 + shift)) & 0xff) / 255)
        colors.append(Float((rgba >> (8 + shift)) & 0xff) / 255)
        colors.append(Float((rgba >> shift) & 0xff) / 255)
        colors.append(shift == 8 ? Float(rgba & 0xff) / 255 : 1)
    }

    private static func parseTransform(_ value: String) throws -> [Double] {
        let parts = value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        let numbers = parts.compactMap { Double($0) }
        if numbers.count != 12 || parts.count != 12 {
            throw AttributeError(message: "Invalid transform: \(value)")
        }
        return numbers
    }
}
