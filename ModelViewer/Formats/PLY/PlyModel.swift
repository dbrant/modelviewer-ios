//
//  PlyModel.swift
//  ModelViewer
//
//  Info on the PLY format: https://en.wikipedia.org/wiki/PLY_(file_format)
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

/// A model from a PLY (Stanford) file, in ASCII or binary (either byte order). A file with faces is
/// shown as a mesh, and a file with only vertices is shown as a point cloud.
final class PlyModel: MeshModel, @unchecked Sendable {
    /// Color of points in point clouds without vertex colors.
    private static let pointColor: [Float] = [1, 1, 1, 1]

    // Vertex color properties may be named either "red" or "diffuse_red", etc.
    private static let redNames: Set<String> = ["red", "diffuse_red"]
    private static let greenNames: Set<String> = ["green", "diffuse_green"]
    private static let blueNames: Set<String> = ["blue", "diffuse_blue"]
    private static let alphaNames: Set<String> = ["alpha", "diffuse_alpha"]

    /// Largest header that's searched for its end.
    private static let maxHeaderSize = 1 << 20

    init(data: Data) throws {
        super.init()
        try read(data.rebased)
        if vertexCount <= 0 {
            throw ModelError.invalidModel
        }
    }

    // MARK: - Header

    private enum ScalarType {
        case int8, uint8, int16, uint16, int32, uint32, int64, uint64, float32, float64

        init?(_ name: String) {
            switch name {
            case "char", "int8": self = .int8
            case "uchar", "uint8": self = .uint8
            case "short", "int16": self = .int16
            case "ushort", "uint16": self = .uint16
            case "int", "int32": self = .int32
            case "uint", "uint32": self = .uint32
            case "long", "int64": self = .int64
            case "ulong", "uint64": self = .uint64
            case "float", "float32": self = .float32
            case "double", "float64": self = .float64
            default: return nil
            }
        }

        var size: Int {
            switch self {
            case .int8, .uint8: 1
            case .int16, .uint16: 2
            case .int32, .uint32, .float32: 4
            case .int64, .uint64, .float64: 8
            }
        }

        /// Factor that converts a color component of this type to the range from 0 to 1.
        var colorScale: Float {
            switch self {
            case .int8, .uint8: 1 / 255
            case .int16, .uint16: 1 / 65535
            case .int32, .uint32, .int64, .uint64: 1 / 255
            case .float32, .float64: 1
            }
        }
    }

    private struct Property {
        let name: String
        let type: ScalarType
        /// For a list property, the type of its count (and `type` is the type of its items).
        let countType: ScalarType?
    }

    private struct Element {
        let name: String
        let count: Int
        var properties: [Property] = []

        func index(of names: Set<String>) -> Int? {
            properties.firstIndex { names.contains($0.name) && $0.countType == nil }
        }
    }

    private enum Format {
        case ascii, binaryLittleEndian, binaryBigEndian
    }

    private struct Header {
        var format = Format.ascii
        var elements: [Element] = []
        /// Offset of the data that follows the header.
        var dataStart = 0
    }

    private static func readHeader(_ data: Data) throws -> Header {
        var scanner = TextScanner(data.prefix(maxHeaderSize))
        var header = Header()
        var sawMagic = false
        var sawEnd = false
        while let rawLine = scanner.nextLine() {
            let line = scanner.trimmed(rawLine)
            if line.isEmpty {
                continue
            }
            let tokens = scanner.tokens(in: line).map { scanner.string($0) }
            if !sawMagic {
                guard tokens[0] == "ply" else {
                    throw ModelError("Not a PLY file.")
                }
                sawMagic = true
                continue
            }
            switch tokens[0] {
            case "format":
                let format = tokens.count > 1 ? tokens[1] : ""
                if format.contains("binary") {
                    header.format = format.contains("big") ? .binaryBigEndian : .binaryLittleEndian
                }
            case "element":
                guard tokens.count >= 3, let count = Int(tokens[2]), count >= 0 else {
                    throw ModelError("Invalid element in PLY header.")
                }
                header.elements.append(Element(name: tokens[1], count: count))
            case "property":
                guard !header.elements.isEmpty else {
                    continue
                }
                let property: Property
                if tokens.count >= 5 && tokens[1] == "list" {
                    guard let countType = ScalarType(tokens[2]), let itemType = ScalarType(tokens[3]) else {
                        throw ModelError("Unsupported property type in PLY header: \(tokens[2]) \(tokens[3])")
                    }
                    property = Property(name: tokens[tokens.count - 1], type: itemType, countType: countType)
                } else if tokens.count >= 3, let type = ScalarType(tokens[1]) {
                    property = Property(name: tokens[tokens.count - 1], type: type, countType: nil)
                } else {
                    throw ModelError("Unsupported property type in PLY header: \(tokens.dropFirst().joined(separator: " "))")
                }
                header.elements[header.elements.count - 1].properties.append(property)
            case "end_header":
                sawEnd = true
            default:
                // "comment", "obj_info", etc.
                break
            }
            if sawEnd {
                header.dataStart = scanner.position
                break
            }
        }
        if !sawEnd {
            throw ModelError("Invalid PLY header.")
        }
        return header
    }

    // MARK: - Reading

    /// Where the properties of interest are, among the properties of the vertex element.
    private struct VertexLayout {
        var x = -1, y = -1, z = -1
        var nx = -1, ny = -1, nz = -1
        var r = -1, g = -1, b = -1, a = -1

        init(_ element: Element) {
            func find(_ names: Set<String>) -> Int { element.index(of: names) ?? -1 }
            x = find(["x"])
            y = find(["y"])
            z = find(["z"])
            nx = find(["nx"])
            ny = find(["ny"])
            nz = find(["nz"])
            r = find(PlyModel.redNames)
            g = find(PlyModel.greenNames)
            b = find(PlyModel.blueNames)
            a = find(PlyModel.alphaNames)
        }

        var hasColors: Bool { r >= 0 && g >= 0 && b >= 0 }
        var hasNormals: Bool { nx >= 0 && ny >= 0 && nz >= 0 }
    }

    /// The data that's read from the file.
    private struct Contents {
        var vertices: [Float] = []
        var fileNormals: [Float] = []
        var colors: [Float] = []
        var indices: [UInt32] = []
        var hasFaces = false
    }

    private func read(_ data: Data) throws {
        let header = try Self.readHeader(data)
        guard let vertexElement = header.elements.first(where: { $0.name == "vertex" }), vertexElement.count > 0 else {
            throw ModelError("No vertices found in model.")
        }
        let layout = VertexLayout(vertexElement)
        guard layout.x >= 0, layout.y >= 0, layout.z >= 0 else {
            throw ModelError("Vertices in model have no positions.")
        }

        var contents = Contents()
        contents.vertices.reserveCapacity(vertexElement.count * 3)
        contents.colors.reserveCapacity(vertexElement.count * 4)
        if header.format == .ascii {
            try readText(data, header, layout, &contents)
        } else {
            try readBinary(data, header, layout, &contents)
        }

        let vertexCount = contents.vertices.count / 3
        // Faces with indices out of range make the model invalid.
        for index in contents.indices where Int(index) >= vertexCount {
            throw ModelError("Invalid face in model.")
        }

        vertices = contents.vertices
        isPointCloud = contents.indices.isEmpty
        if !isPointCloud {
            indices = contents.indices
            normals = layout.hasNormals ? contents.fileNormals : Self.faceNormals(contents.vertices, contents.indices)
        }
        // Point clouds always need colors, but meshes only have them if the file does.
        if isPointCloud || layout.hasColors {
            colors = contents.colors
        }
        computeBoundsFromVertices()
    }

    /// Normals for each vertex, which are those of the last face (or triangle of a polygon) that uses the vertex.
    private static func faceNormals(_ vertices: [Float], _ indices: [UInt32]) -> [Float] {
        var normals = [Float](repeating: 0, count: vertices.count)
        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]) * 3, b = Int(indices[i + 1]) * 3, c = Int(indices[i + 2]) * 3
            let n = Transforms.calculateNormal(vertices[a], vertices[a + 1], vertices[a + 2],
                                               vertices[b], vertices[b + 1], vertices[b + 2],
                                               vertices[c], vertices[c + 1], vertices[c + 2])
            for k in [a, b, c] {
                normals[k] = n.x
                normals[k + 1] = n.y
                normals[k + 2] = n.z
            }
            i += 3
        }
        return normals
    }

    /// Adds the triangles of a polygon (as a fan), given the indices of its corners.
    @inline(__always)
    private static func addPolygon(_ corners: UnsafeMutableBufferPointer<UInt32>, _ count: Int, _ indices: inout [UInt32]) {
        if count < 3 {
            return
        }
        for k in 1..<(count - 1) {
            indices.append(corners[0])
            indices.append(corners[k])
            indices.append(corners[k + 1])
        }
    }

    private static func isFaceIndexList(_ property: Property) -> Bool {
        property.countType != nil && (property.name == "vertex_indices" || property.name == "vertex_index")
    }

    // MARK: ASCII

    private func readText(_ data: Data, _ header: Header, _ layout: VertexLayout, _ contents: inout Contents) throws {
        var scanner = TextScanner(data, position: header.dataStart)
        var corners = [UInt32](repeating: 0, count: 64)

        for element in header.elements {
            if contents.hasFaces && element.name != "vertex" && element.name != "face" {
                // Nothing else is needed.
                break
            }
            var row = 0
            while row < element.count {
                guard let rawLine = scanner.nextLine() else {
                    throw ModelError.unexpectedEnd
                }
                let line = scanner.trimmed(rawLine)
                if line.isEmpty {
                    continue
                }
                row += 1
                if element.name == "vertex" {
                    let tokens = scanner.tokens(in: line)
                    func value(_ index: Int) throws -> Float {
                        guard index < tokens.count, let v = scanner.float(tokens[index]) else {
                            throw ModelError("Invalid vertex in model.")
                        }
                        return v
                    }
                    // Lists in vertices aren't expected, so tokens correspond to properties.
                    contents.vertices.append(try value(layout.x))
                    contents.vertices.append(try value(layout.y))
                    contents.vertices.append(try value(layout.z))
                    if layout.hasNormals {
                        contents.fileNormals.append(try value(layout.nx))
                        contents.fileNormals.append(try value(layout.ny))
                        contents.fileNormals.append(try value(layout.nz))
                    }
                    if layout.hasColors {
                        let p = element.properties
                        contents.colors.append(try value(layout.r) * p[layout.r].type.colorScale)
                        contents.colors.append(try value(layout.g) * p[layout.g].type.colorScale)
                        contents.colors.append(try value(layout.b) * p[layout.b].type.colorScale)
                        contents.colors.append(try (layout.a >= 0 ? value(layout.a) * p[layout.a].type.colorScale : 1))
                    } else {
                        contents.colors.append(contentsOf: Self.pointColor)
                    }
                } else if element.name == "face" {
                    contents.hasFaces = true
                    let tokens = scanner.tokens(in: line)
                    var t = 0
                    for property in element.properties {
                        if property.countType != nil {
                            guard t < tokens.count, let n = scanner.int(tokens[t]), n >= 0, t + n < tokens.count else {
                                throw ModelError("Invalid face in model.")
                            }
                            t += 1
                            if Self.isFaceIndexList(property) {
                                if n > corners.count {
                                    corners = [UInt32](repeating: 0, count: n)
                                }
                                for k in 0..<n {
                                    guard let index = scanner.int(tokens[t + k]), index >= 0 else {
                                        throw ModelError("Invalid face in model.")
                                    }
                                    corners[k] = UInt32(truncatingIfNeeded: index)
                                }
                                corners.withUnsafeMutableBufferPointer { Self.addPolygon($0, n, &contents.indices) }
                            }
                            t += n
                        } else {
                            t += 1
                        }
                    }
                }
            }
        }
    }

    // MARK: Binary

    @inline(__always)
    private static func readScalar(_ raw: UnsafeRawBufferPointer, _ offset: Int, _ type: ScalarType, _ bigEndian: Bool) -> Double {
        switch type {
        case .int8: return Double(raw.load(fromByteOffset: offset, as: Int8.self))
        case .uint8: return Double(raw[offset])
        case .int16:
            let v = raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)
            return Double(bigEndian ? Int16(bigEndian: v) : Int16(littleEndian: v))
        case .uint16:
            let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            return Double(bigEndian ? UInt16(bigEndian: v) : UInt16(littleEndian: v))
        case .int32:
            let v = raw.loadUnaligned(fromByteOffset: offset, as: Int32.self)
            return Double(bigEndian ? Int32(bigEndian: v) : Int32(littleEndian: v))
        case .uint32:
            let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            return Double(bigEndian ? UInt32(bigEndian: v) : UInt32(littleEndian: v))
        case .int64:
            let v = raw.loadUnaligned(fromByteOffset: offset, as: Int64.self)
            return Double(bigEndian ? Int64(bigEndian: v) : Int64(littleEndian: v))
        case .uint64:
            let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            return Double(bigEndian ? UInt64(bigEndian: v) : UInt64(littleEndian: v))
        case .float32:
            let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            return Double(Float(bitPattern: bigEndian ? UInt32(bigEndian: v) : UInt32(littleEndian: v)))
        case .float64:
            let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            return Double(bitPattern: bigEndian ? UInt64(bigEndian: v) : UInt64(littleEndian: v))
        }
    }

    /// Reads an integer (a list count or index), which must be in the range of an Int.
    @inline(__always)
    private static func readIndex(_ raw: UnsafeRawBufferPointer, _ offset: Int, _ type: ScalarType, _ bigEndian: Bool) throws -> Int {
        let value = readScalar(raw, offset, type, bigEndian)
        guard value >= 0, value < Double(UInt32.max) else {
            throw ModelError("Invalid face in model.")
        }
        return Int(value)
    }

    private func readBinary(_ data: Data, _ header: Header, _ layout: VertexLayout, _ contents: inout Contents) throws {
        let bigEndian = header.format == .binaryBigEndian
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = header.dataStart
            let end = raw.count
            var corners = [UInt32](repeating: 0, count: 64)

            func require(_ n: Int) throws {
                if n < 0 || offset > end - n {
                    throw ModelError.unexpectedEnd
                }
            }

            for element in header.elements {
                if contents.hasFaces && element.name != "vertex" && element.name != "face" {
                    break
                }
                let properties = element.properties
                let hasLists = properties.contains { $0.countType != nil }

                if element.name == "vertex" && !hasLists {
                    // Fixed-size rows: find the offsets of the properties within each row.
                    var offsets = [Int]()
                    var rowSize = 0
                    for property in properties {
                        offsets.append(rowSize)
                        rowSize += property.type.size
                    }
                    try require(rowSize * element.count)
                    let p = properties
                    for _ in 0..<element.count {
                        @inline(__always) func value(_ index: Int) -> Float {
                            Float(Self.readScalar(raw, offset + offsets[index], p[index].type, bigEndian))
                        }
                        contents.vertices.append(value(layout.x))
                        contents.vertices.append(value(layout.y))
                        contents.vertices.append(value(layout.z))
                        if layout.hasNormals {
                            contents.fileNormals.append(value(layout.nx))
                            contents.fileNormals.append(value(layout.ny))
                            contents.fileNormals.append(value(layout.nz))
                        }
                        if layout.hasColors {
                            contents.colors.append(value(layout.r) * p[layout.r].type.colorScale)
                            contents.colors.append(value(layout.g) * p[layout.g].type.colorScale)
                            contents.colors.append(value(layout.b) * p[layout.b].type.colorScale)
                            contents.colors.append(layout.a >= 0 ? value(layout.a) * p[layout.a].type.colorScale : 1)
                        } else {
                            contents.colors.append(contentsOf: Self.pointColor)
                        }
                        offset += rowSize
                    }
                    continue
                }

                if element.name != "vertex" && element.name != "face" && !hasLists {
                    // Skip other elements whole.
                    let rowSize = properties.reduce(0) { $0 + $1.type.size }
                    try require(rowSize * element.count)
                    offset += rowSize * element.count
                    continue
                }

                // Rows of varying size, which are read property by property.
                let isFace = element.name == "face"
                let isVertex = element.name == "vertex"
                if isFace {
                    contents.hasFaces = true
                    contents.indices.reserveCapacity(element.count * 3)
                }
                var values = [Float](repeating: 0, count: properties.count)
                for _ in 0..<element.count {
                    for (i, property) in properties.enumerated() {
                        if let countType = property.countType {
                            try require(countType.size)
                            let n = try Self.readIndex(raw, offset, countType, bigEndian)
                            offset += countType.size
                            try require(n * property.type.size)
                            if isFace && Self.isFaceIndexList(property) {
                                if n > corners.count {
                                    corners = [UInt32](repeating: 0, count: n)
                                }
                                for k in 0..<n {
                                    corners[k] = UInt32(try Self.readIndex(raw, offset + k * property.type.size, property.type, bigEndian))
                                }
                                corners.withUnsafeMutableBufferPointer { Self.addPolygon($0, n, &contents.indices) }
                            }
                            offset += n * property.type.size
                        } else {
                            try require(property.type.size)
                            if isVertex {
                                values[i] = Float(Self.readScalar(raw, offset, property.type, bigEndian))
                            }
                            offset += property.type.size
                        }
                    }
                    if isVertex {
                        contents.vertices.append(values[layout.x])
                        contents.vertices.append(values[layout.y])
                        contents.vertices.append(values[layout.z])
                        if layout.hasNormals {
                            contents.fileNormals.append(values[layout.nx])
                            contents.fileNormals.append(values[layout.ny])
                            contents.fileNormals.append(values[layout.nz])
                        }
                        if layout.hasColors {
                            contents.colors.append(values[layout.r] * properties[layout.r].type.colorScale)
                            contents.colors.append(values[layout.g] * properties[layout.g].type.colorScale)
                            contents.colors.append(values[layout.b] * properties[layout.b].type.colorScale)
                            contents.colors.append(layout.a >= 0 ? values[layout.a] * properties[layout.a].type.colorScale : 1)
                        } else {
                            contents.colors.append(contentsOf: Self.pointColor)
                        }
                    }
                }
            }
        }
    }
}
