//
//  ObjModel.swift
//  ModelViewer
//
//  Info on the OBJ format: https://en.wikipedia.org/wiki/Wavefront_.obj_file
//  Materials are read from the material libraries (.mtl files) that the model refers to, which are
//  found through the model's resources, along with their textures.
//
//  Copyright 2017-2026 Dmitry Brant. All rights reserved.
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

final class ObjModel: MeshModel, @unchecked Sendable {
    init(data: Data, resources: ModelResources) throws {
        super.init()
        var parser = ObjParser(resources: resources)
        try parser.read(data)
        try parser.build(into: self)
        if vertexCount <= 0 || indexCount <= 0 {
            throw ModelError.invalidModel
        }
    }
}

/// The state of reading an OBJ file.
private struct ObjParser {
    let resources: ModelResources

    var positions: [Float] = []
    var colors: [Float] = []
    var hasColors = false
    var maxColor: Float = 0
    var texCoords: [Float] = []
    var normals: [Float] = []
    var minPosition = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    var maxPosition = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
    var sum = SIMD3<Double>(0, 0, 0)

    // Each distinct combination of position, texture coordinate, and normal that's used by a face
    // becomes a vertex of the mesh. Vertices that share a position are linked together, for finding them quickly.
    var vertexPosition: [Int32] = []
    var vertexTexCoord: [Int32] = []
    var vertexNormal: [Int32] = []
    var nextVertexWithPosition: [Int32] = []
    var firstVertexWithPosition: [Int32] = []

    var materials: [String: Material] = [:]
    var textures: [String: Data?] = [:]

    // Triangles (as vertex indices) for each material, in the order in which the materials are first used.
    var materialOrder: [String] = [""]
    var trianglesByMaterial: [[UInt32]] = [[]]
    var materialIndex: [String: Int] = ["": 0]

    init(resources: ModelResources) {
        self.resources = resources
    }

    mutating func read(_ data: Data) throws {
        var scanner = TextScanner(data)
        var current = 0
        var faceVertices: [UInt32] = []
        faceVertices.reserveCapacity(16)
        positions.reserveCapacity(data.count / 16)

        while let rawLine = scanner.nextLine() {
            let line = scanner.trimmed(rawLine)
            if line.isEmpty || scanner.bytes[line.lowerBound] == UInt8(ascii: "#") {
                continue
            }
            let tokens = scanner.tokens(in: line)
            let keyword = tokens[0]
            if scanner.equals(keyword, "v") {
                guard tokens.count >= 4 else {
                    throw ModelError("Invalid vertex: \(scanner.string(line))")
                }
                guard let x = scanner.float(tokens[1]), let y = scanner.float(tokens[2]), let z = scanner.float(tokens[3]) else {
                    throw ModelError("Invalid vertex: \(scanner.string(line))")
                }
                positions.append(x)
                positions.append(y)
                positions.append(z)
                let p = SIMD3(x, y, z)
                minPosition = pointwiseMin(minPosition, p)
                maxPosition = pointwiseMax(maxPosition, p)
                sum += SIMD3<Double>(Double(x), Double(y), Double(z))
                firstVertexWithPosition.append(-1)
                if tokens.count == 7 {
                    if !hasColors {
                        // Vertices before the first one with a color are white.
                        hasColors = true
                        colors.append(contentsOf: repeatElement(1, count: positions.count - 3))
                    }
                    for i in 4...6 {
                        guard let c = scanner.float(tokens[i]) else {
                            throw ModelError("Invalid vertex: \(scanner.string(line))")
                        }
                        maxColor = max(maxColor, c)
                        colors.append(c)
                    }
                } else if hasColors {
                    colors.append(contentsOf: [1, 1, 1])
                }
            } else if scanner.equals(keyword, "vt") {
                for i in 1...2 {
                    if i < tokens.count {
                        guard let value = scanner.float(tokens[i]) else {
                            throw ModelError("Invalid texture coordinate: \(scanner.string(line))")
                        }
                        texCoords.append(value)
                    } else {
                        texCoords.append(0)
                    }
                }
            } else if scanner.equals(keyword, "vn") {
                guard tokens.count >= 4, let x = scanner.float(tokens[1]), let y = scanner.float(tokens[2]),
                      let z = scanner.float(tokens[3]) else {
                    throw ModelError("Invalid normal: \(scanner.string(line))")
                }
                normals.append(x)
                normals.append(y)
                normals.append(z)
            } else if scanner.equals(keyword, "f") {
                faceVertices.removeAll(keepingCapacity: true)
                for i in 1..<tokens.count {
                    faceVertices.append(try vertexFor(tokens[i], scanner))
                }
                // Split polygons into a fan of triangles.
                if faceVertices.count >= 3 {
                    for i in 1..<(faceVertices.count - 1) {
                        trianglesByMaterial[current].append(faceVertices[0])
                        trianglesByMaterial[current].append(faceVertices[i])
                        trianglesByMaterial[current].append(faceVertices[i + 1])
                    }
                }
            } else if scanner.equals(keyword, "usemtl") {
                let name = scanner.string(scanner.trimmed(keyword.upperBound..<line.upperBound))
                if let index = materialIndex[name] {
                    current = index
                } else {
                    current = materialOrder.count
                    materialIndex[name] = current
                    materialOrder.append(name)
                    trianglesByMaterial.append([])
                }
            } else if scanner.equals(keyword, "mtllib") {
                readMaterialLibraries(scanner.string(scanner.trimmed(keyword.upperBound..<line.upperBound)))
            }
        }
    }

    /// Returns the mesh vertex for a face corner, which is given as "v", "v/vt", "v//vn", or "v/vt/vn"
    /// (each a 1-based index, or a negative index relative to the end of the list).
    private mutating func vertexFor(_ corner: Range<Int>, _ scanner: TextScanner) throws -> UInt32 {
        // Split the corner at its slashes.
        var fields: [Range<Int>] = []
        var start = corner.lowerBound
        for i in corner where scanner.bytes[i] == UInt8(ascii: "/") {
            fields.append(start..<i)
            start = i + 1
        }
        fields.append(start..<corner.upperBound)

        let p = Int(try resolveIndex(fields[0], positions.count / 3, corner, scanner))
        let t = fields.count > 1 && !fields[1].isEmpty ? try resolveIndex(fields[1], texCoords.count / 2, corner, scanner) : -1
        let n = fields.count > 2 && !fields[2].isEmpty ? try resolveIndex(fields[2], normals.count / 3, corner, scanner) : -1

        var v = firstVertexWithPosition[p]
        while v >= 0 {
            if vertexTexCoord[Int(v)] == t && vertexNormal[Int(v)] == n {
                return UInt32(v)
            }
            v = nextVertexWithPosition[Int(v)]
        }
        v = Int32(vertexPosition.count)
        vertexPosition.append(Int32(p))
        vertexTexCoord.append(t)
        vertexNormal.append(n)
        nextVertexWithPosition.append(firstVertexWithPosition[p])
        firstVertexWithPosition[p] = v
        return UInt32(v)
    }

    private func resolveIndex(_ field: Range<Int>, _ count: Int, _ corner: Range<Int>, _ scanner: TextScanner) throws -> Int32 {
        guard let index = scanner.int(field) else {
            throw ModelError("Invalid face: \(scanner.string(corner))")
        }
        let resolved = index < 0 ? count + index : index - 1
        guard resolved >= 0 && resolved < count else {
            throw ModelError("Invalid face: \(scanner.string(corner))")
        }
        return Int32(resolved)
    }

    // MARK: - Building the mesh

    func build(into model: MeshModel) throws {
        let vertexCount = vertexPosition.count
        let positionCount = positions.count / 3
        if positionCount > 0 {
            model.centerMassX = Float(sum.x / Double(positionCount))
            model.centerMassY = Float(sum.y / Double(positionCount))
            model.centerMassZ = Float(sum.z / Double(positionCount))
            model.minX = minPosition.x
            model.minY = minPosition.y
            model.minZ = minPosition.z
            model.maxX = maxPosition.x
            model.maxY = maxPosition.y
            model.maxZ = maxPosition.z
        }

        var vertices = [Float](repeating: 0, count: vertexCount * 3)
        for v in 0..<vertexCount {
            let p = Int(vertexPosition[v]) * 3
            vertices[v * 3] = positions[p]
            vertices[v * 3 + 1] = positions[p + 1]
            vertices[v * 3 + 2] = positions[p + 2]
        }
        model.vertices = vertices

        // Combine the triangles of all materials into one array, with a part for each material.
        var indices: [UInt32] = []
        indices.reserveCapacity(trianglesByMaterial.reduce(0) { $0 + $1.count })
        var parts: [MeshPart] = []
        let useMaterials = materialOrder.contains { materials[$0] != nil }
        for (i, name) in materialOrder.enumerated() {
            let list = trianglesByMaterial[i]
            if list.isEmpty {
                continue
            }
            if useMaterials {
                // A material that wasn't found in the libraries gets the default gray.
                parts.append(MeshPart(material: materials[name] ?? Material(name: name), first: indices.count, count: list.count))
            }
            indices.append(contentsOf: list)
        }
        model.indices = indices
        model.parts = parts
        model.normals = buildNormals(indices)

        if hasColors {
            // Colors may be given from 0 to 1, or sometimes from 0 to 255.
            let scale: Float = maxColor > 1 ? 1 / 255 : 1
            var colorArray = [Float](repeating: 0, count: vertexCount * 4)
            for v in 0..<vertexCount {
                let p = Int(vertexPosition[v]) * 3
                colorArray[v * 4] = colors[p] * scale
                colorArray[v * 4 + 1] = colors[p + 1] * scale
                colorArray[v * 4 + 2] = colors[p + 2] * scale
                colorArray[v * 4 + 3] = 1
            }
            model.colors = colorArray
        }

        // Texture coordinates are only useful if there are textures.
        if parts.contains(where: { $0.material.diffuseTexture != nil }) {
            var texCoordArray = [Float](repeating: 0, count: vertexCount * 2)
            for v in 0..<vertexCount {
                let t = Int(vertexTexCoord[v])
                if t >= 0 {
                    texCoordArray[v * 2] = texCoords[t * 2]
                    texCoordArray[v * 2 + 1] = texCoords[t * 2 + 1]
                }
            }
            model.texCoords = texCoordArray
        }
    }

    /// Uses the normals given in the file, and for any vertices without one, computes a smooth
    /// normal from the faces around its position.
    private func buildNormals(_ indices: [UInt32]) -> [Float] {
        let vertexCount = vertexPosition.count
        var normalArray = [Float](repeating: 0, count: vertexCount * 3)
        var needsComputedNormals = false
        for v in 0..<vertexCount {
            let n = Int(vertexNormal[v])
            if n >= 0 {
                normalArray[v * 3] = normals[n * 3]
                normalArray[v * 3 + 1] = normals[n * 3 + 1]
                normalArray[v * 3 + 2] = normals[n * 3 + 2]
            } else {
                needsComputedNormals = true
            }
        }
        if !needsComputedNormals {
            return normalArray
        }
        // Accumulate the (area-weighted) normals of the faces around each position.
        let p = positions
        var positionNormals = [Float](repeating: 0, count: positions.count)
        var i = 0
        while i + 2 < indices.count {
            let a = Int(vertexPosition[Int(indices[i])]) * 3
            let b = Int(vertexPosition[Int(indices[i + 1])]) * 3
            let c = Int(vertexPosition[Int(indices[i + 2])]) * 3
            let e1x = p[b] - p[a], e1y = p[b + 1] - p[a + 1], e1z = p[b + 2] - p[a + 2]
            let e2x = p[c] - p[a], e2y = p[c + 1] - p[a + 1], e2z = p[c + 2] - p[a + 2]
            let nx = e1y * e2z - e1z * e2y
            let ny = e1z * e2x - e1x * e2z
            let nz = e1x * e2y - e1y * e2x
            for k in [a, b, c] {
                positionNormals[k] += nx
                positionNormals[k + 1] += ny
                positionNormals[k + 2] += nz
            }
            i += 3
        }
        for v in 0..<vertexCount where vertexNormal[v] < 0 {
            let k = Int(vertexPosition[v]) * 3
            let x = positionNormals[k], y = positionNormals[k + 1], z = positionNormals[k + 2]
            let length = (x * x + y * y + z * z).squareRoot()
            if length > 0 {
                normalArray[v * 3] = x / length
                normalArray[v * 3 + 1] = y / length
                normalArray[v * 3 + 2] = z / length
            }
        }
        return normalArray
    }

    // MARK: - Materials

    private static func split(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private mutating func readMaterialLibraries(_ names: String) {
        // A line can list several libraries, but a single file name might also contain spaces.
        let files = Self.split(names)
        if files.count > 1 && files.allSatisfy({ $0.lowercased().hasSuffix(".mtl") }) {
            for file in files {
                readMaterialLibrary(file)
            }
        } else {
            readMaterialLibrary(names)
        }
    }

    private mutating func readMaterialLibrary(_ name: String) {
        guard let data = resources.open(name) else {
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        var material: Material?
        var hasDiffuseColor = Set<ObjectIdentifier>()
        var hasOpacity = Set<ObjectIdentifier>()

        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            let tokens = Self.split(line)
            let keyword = tokens[0].lowercased()
            if keyword == "newmtl" {
                let materialName = String(line.dropFirst(tokens[0].count)).trimmingCharacters(in: .whitespaces)
                let m = Material(name: materialName)
                materials[materialName] = m
                material = m
                continue
            }
            guard let m = material else {
                continue
            }
            // Values that can't be parsed are ignored, since the model is still useful without them.
            switch keyword {
            case "kd":
                if let color = Self.parseColor(tokens) {
                    m.diffuseColor = color
                    hasDiffuseColor.insert(ObjectIdentifier(m))
                }
            case "ks":
                if let color = Self.parseColor(tokens) { m.specularColor = color }
            case "ke":
                if let color = Self.parseColor(tokens) { m.emissiveColor = color }
            case "ns":
                if tokens.count > 1, let value = Float(tokens[1]) { m.shininess = value }
            case "d":
                if let value = Float(tokens[tokens.count - 1]) {
                    m.opacity = min(max(value, 0), 1)
                    hasOpacity.insert(ObjectIdentifier(m))
                }
            case "tr":
                // "Tr" is the inverse of "d", but some exporters write "Tr 1" for opaque materials.
                if tokens.count > 1, let value = Float(tokens[1]), !hasOpacity.contains(ObjectIdentifier(m)), value < 1 {
                    m.opacity = min(max(1 - value, 0), 1)
                }
            case "illum":
                if tokens.count > 1, let value = Int(tokens[1]) {
                    m.lighting = switch value {
                    case 0: .none
                    case 1: .diffuse
                    default: .specular
                    }
                }
            case "map_kd":
                readTextureMap(tokens, m)
            default:
                break
            }
        }
        // A texture without a diffuse color is shown as is.
        for m in materials.values where m.diffuseTexture != nil && !hasDiffuseColor.contains(ObjectIdentifier(m)) {
            m.diffuseColor = SIMD3(1, 1, 1)
        }
    }

    private static func parseColor(_ tokens: [String]) -> SIMD3<Float>? {
        // Colors can also be given as "spectral" curves or in CIE XYZ space, which aren't supported.
        guard tokens.count > 1, let r = Float(tokens[1]) else {
            return nil
        }
        let g = tokens.count > 2 ? Float(tokens[2]) ?? r : r
        let b = tokens.count > 3 ? Float(tokens[3]) ?? r : r
        return SIMD3(r, g, b)
    }

    /// Reads a texture map statement, which is the file name, preceded by options such as "-s 2 2"
    /// (which scales the texture coordinates) or "-o 0.5 0" (which offsets them).
    private mutating func readTextureMap(_ tokens: [String], _ material: Material) {
        var i = 1
        // Options start with "-", but the last token is always (part of) the file name.
        while i < tokens.count - 1 && tokens[i].hasPrefix("-") {
            let option = tokens[i].lowercased()
            i += 1
            switch option {
            case "-o", "-s", "-t":
                // From one to three numbers (u, v, w)
                var values: [Float] = []
                while values.count < 3 && i < tokens.count - 1, let value = Float(tokens[i]) {
                    values.append(value)
                    i += 1
                }
                if option == "-s" && !values.isEmpty {
                    material.textureScale = SIMD2(values[0], values.count > 1 ? values[1] : 1)
                } else if option == "-o" && !values.isEmpty {
                    material.textureOffset = SIMD2(values[0], values.count > 1 ? values[1] : 0)
                }
            case "-mm":
                i += 2
            default:
                i += 1
            }
        }
        if i >= tokens.count {
            return
        }
        let fileName = tokens[i...].joined(separator: " ")
        let data: Data?
        if let cached = textures[fileName] {
            data = cached
        } else {
            data = resources.open(fileName)
            textures[fileName] = .some(data)
        }
        if let data {
            material.diffuseTexture = data
            material.diffuseTextureName = fileName
        }
    }
}
