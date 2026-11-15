//
//  StlModel.swift
//  ModelViewer
//
//  Info on the STL format: https://en.wikipedia.org/wiki/STL_(file_format)
//  Binary STL files may have per-facet colors, which are not part of the standard, but are stored
//  in the unused "attribute" field of each facet in one of two ways, by VisCAM/SolidView or by
//  Materialise Magics (as described in the above article).
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

final class StlModel: MeshModel, @unchecked Sendable {
    private static let headerSize = 80
    private static let asciiTestSize = 256
    private static let defaultFacetColor: [Float] = [0.8, 0.8, 0.8, 1]

    override var orientation: ModelOrientation { .zUp }

    init(data: Data) throws {
        super.init()
        let data = data.rebased
        if Self.isTextFormat(data) {
            try readText(data)
        } else {
            try readBinary(data)
        }
        if vertexCount <= 0 || normals.count != vertices.count {
            throw ModelError.invalidModel
        }
    }

    private static func isTextFormat(_ data: Data) -> Bool {
        let string = String(decoding: data.prefix(asciiTestSize), as: UTF8.self)
        return string.contains("solid") && string.contains("facet") && string.contains("vertex")
    }

    private func readText(_ data: Data) throws {
        var scanner = TextScanner(data)
        var vertices: [Float] = []
        var normals: [Float] = []
        vertices.reserveCapacity(data.count / 40)
        normals.reserveCapacity(data.count / 40)
        while let rawLine = scanner.nextLine() {
            let line = scanner.trimmed(rawLine)
            if scanner.hasPrefix(line, "facet") {
                // "facet normal x y z"
                let tokens = scanner.tokens(in: line)
                guard tokens.count >= 5 else { throw ModelError.invalidModel }
                guard let x = scanner.float(tokens[2]), let y = scanner.float(tokens[3]), let z = scanner.float(tokens[4]) else {
                    throw ModelError.invalidModel
                }
                for _ in 0..<3 {
                    normals.append(x)
                    normals.append(y)
                    normals.append(z)
                }
            } else if scanner.hasPrefix(line, "vertex") {
                let tokens = scanner.tokens(in: line)
                guard tokens.count >= 4 else { throw ModelError.invalidModel }
                guard let x = scanner.float(tokens[1]), let y = scanner.float(tokens[2]), let z = scanner.float(tokens[3]) else {
                    throw ModelError.invalidModel
                }
                vertices.append(x)
                vertices.append(y)
                vertices.append(z)
            }
        }
        self.vertices = vertices
        self.normals = normals
        computeBoundsFromVertices()
    }

    private func readBinary(_ data: Data) throws {
        var reader = BinaryReader(data)
        let header = try reader.readBytes(Self.headerSize)
        let objectColor = Self.readObjectColor(header)
        let facetCount = Int(try reader.readUInt32LE())
        let vertexCount = facetCount * 3
        if vertexCount <= 0 || vertexCount > 30_000_000 || reader.remaining < facetCount * 50 {
            throw ModelError.invalidModel
        }

        var vertices = [Float](repeating: 0, count: vertexCount * 3)
        var normals = [Float](repeating: 0, count: vertexCount * 3)
        var colors: [Float]?
        var haveNormals = false
        var facetColor = [Float](repeating: 0, count: 4)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = reader.position
            func f(_ o: Int) -> Float {
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + o, as: UInt32.self)))
            }
            for i in 0..<facetCount {
                let attribute = Int(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 48, as: UInt16.self)))
                if Self.readFacetColor(attribute, objectColor, &facetColor) {
                    if colors == nil {
                        // Facets without their own color, before this one, get the default color.
                        var c = [Float](repeating: 0, count: vertexCount * 4)
                        for j in 0..<(i * 3) {
                            c.replaceSubrange((j * 4)..<(j * 4 + 4), with: Self.defaultFacetColor)
                        }
                        colors = c
                    }
                    for j in 0..<3 {
                        colors!.replaceSubrange(((i * 3 + j) * 4)..<((i * 3 + j) * 4 + 4), with: facetColor)
                    }
                } else if colors != nil {
                    for j in 0..<3 {
                        colors!.replaceSubrange(((i * 3 + j) * 4)..<((i * 3 + j) * 4 + 4), with: Self.defaultFacetColor)
                    }
                }

                let nx = f(0), ny = f(4), nz = f(8)
                if !haveNormals && (nx != 0 || ny != 0 || nz != 0) {
                    haveNormals = true
                }
                for c in 0..<3 {
                    let v = i * 9 + c * 3
                    normals[v] = nx
                    normals[v + 1] = ny
                    normals[v + 2] = nz
                    vertices[v] = f(12 + c * 12)
                    vertices[v + 1] = f(16 + c * 12)
                    vertices[v + 2] = f(20 + c * 12)
                }
                offset += 50
            }
        }

        if !haveNormals {
            var i = 0
            while i < vertexCount {
                let p = i * 3
                let n = Transforms.calculateNormal(vertices[p], vertices[p + 1], vertices[p + 2],
                                                   vertices[p + 3], vertices[p + 4], vertices[p + 5],
                                                   vertices[p + 6], vertices[p + 7], vertices[p + 8])
                for c in 0..<3 {
                    normals[p + c * 3] = n.x
                    normals[p + c * 3 + 1] = n.y
                    normals[p + c * 3 + 2] = n.z
                }
                i += 3
            }
        }

        self.vertices = vertices
        self.normals = normals
        self.colors = colors
        computeBoundsFromVertices()
    }

    /// Returns the color of the whole object, which Materialise Magics stores in the header as
    /// "COLOR=" followed by RGBA bytes, optionally followed by ",MATERIAL=" and RGBA bytes for the
    /// diffuse, specular, and ambient colors (which take precedence). Returns nil if there's no such color.
    private static func readObjectColor(_ header: [UInt8]) -> [Float]? {
        let text = String(header.map { Character(Unicode.Scalar($0)) })
        guard let colorRange = text.range(of: "COLOR=") else {
            return nil
        }
        let colorPos = text.distance(from: text.startIndex, to: colorRange.lowerBound)
        if colorPos + 10 > header.count {
            return nil
        }
        var pos = colorPos + 6
        let searchStart = text.index(text.startIndex, offsetBy: colorPos + 10)
        if let materialRange = text.range(of: ",MATERIAL=", range: searchStart..<text.endIndex) {
            let materialPos = text.distance(from: text.startIndex, to: materialRange.lowerBound)
            if materialPos + 14 <= header.count {
                pos = materialPos + 10
            }
        }
        return [Float(header[pos]) / 255, Float(header[pos + 1]) / 255, Float(header[pos + 2]) / 255, 1]
    }

    /// Reads the color of a facet from its attribute field, and returns false if it doesn't have one.
    private static func readFacetColor(_ attribute: Int, _ objectColor: [Float]?, _ color: inout [Float]) -> Bool {
        if let objectColor {
            // Magics: the top bit is clear if the facet has its own color, with red in the lowest bits.
            if attribute & 0x8000 == 0 {
                color[0] = Float(attribute & 0x1f) / 31
                color[1] = Float((attribute >> 5) & 0x1f) / 31
                color[2] = Float((attribute >> 10) & 0x1f) / 31
                color[3] = 1
            } else {
                color = objectColor
            }
            return true
        }
        // VisCAM/SolidView: the top bit is set if the facet has a color, with blue in the lowest bits.
        if attribute & 0x8000 != 0 {
            color[0] = Float((attribute >> 10) & 0x1f) / 31
            color[1] = Float((attribute >> 5) & 0x1f) / 31
            color[2] = Float(attribute & 0x1f) / 31
            color[3] = 1
            return true
        }
        return false
    }
}
