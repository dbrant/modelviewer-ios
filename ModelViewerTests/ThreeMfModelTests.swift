//
//  ThreeMfModelTests.swift
//  ModelViewerTests
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
import Compression
import Testing
@testable import ModelViewer

struct ThreeMfModelTests {
    private static let modelStart = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"
            xmlns:m="http://schemas.microsoft.com/3dmanufacturing/material/2015/02"
            xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06">

        """
    private static let modelEnd = "</model>"
    // A triangle in the XY plane, facing +Z.
    private static let triangleMesh = """
        <mesh>
          <vertices>
            <vertex x="0" y="0" z="0"/>
            <vertex x="1" y="0" z="0"/>
            <vertex x="0" y="1" z="0"/>
          </vertices>
          <triangles>
            <triangle v1="0" v2="1" v3="2"/>
          </triangles>
        </mesh>

        """
    private static let tolerance: Float = 1e-5

    @Test func buildItemsAndComponents() throws {
        // The part with the build is named in the package relationships, which come last.
        let files: [(String, Data)] = [
            ("3D/main.model", Self.text(Self.modelStart + """
                <resources>
                  <object id="2" type="model">
                    <components>
                      <component p:path="/3D/Objects/part.model" objectid="1" transform="1 0 0 0 1 0 0 0 1 10 0 0"/>
                    </components>
                  </object>
                  <object id="3" type="model">
                """ + Self.triangleMesh + """
                  </object>
                </resources>
                <build>
                  <item objectid="2" transform="2 0 0 0 2 0 0 0 2 0 0 5"/>
                  <item objectid="3"/>
                </build>
                """ + Self.modelEnd)),
            ("3D/Objects/part.model", Self.text(Self.modelStart + "<resources><object id=\"1\">" + Self.triangleMesh
                                                 + "</object></resources>" + Self.modelEnd)),
            ("_rels/.rels", Self.text("""
                <?xml version="1.0" encoding="UTF-8"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                  <Relationship Target="/Metadata/thumbnail.png" Id="rel-2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail"/>
                  <Relationship Target="/3D/main.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
                </Relationships>
                """)),
        ]

        let model = try Self.load(files)
        #expect(model.vertexCount == 6)
        // The component is translated, and then the build item scales and translates it.
        Self.expectPositions(model, 0, [20, 0, 5, 22, 0, 5, 20, 2, 5])
        Self.expectPositions(model, 3, [0, 0, 0, 1, 0, 0, 0, 1, 0])
        for v in 0..<6 {
            Self.expectNormal(model, v, 0, 0, 1)
        }
        #expect(model.colors == nil)
        #expect(model.texCoords == nil)
        #expect(!model.hasMaterials)
    }

    @Test func mirroredTransform() throws {
        let model = try Self.load([("3D/3dmodel.model", Self.text(Self.modelStart
            + "<resources><object id=\"1\">" + Self.triangleMesh + "</object></resources>"
            + "<build><item objectid=\"1\" transform=\"-1 0 0 0 1 0 0 0 1 0 0 0\"/></build>" + Self.modelEnd))])
        // The corners are reversed, so that the mirrored triangle still faces outward.
        Self.expectPositions(model, 0, [0, 0, 0, 0, 1, 0, -1, 0, 0])
        Self.expectNormal(model, 0, 0, 0, 1)
    }

    @Test func colors() throws {
        let model = try Self.load([("3D/3dmodel.model", Self.text(Self.modelStart + """
            <resources>
              <basematerials id="5">
                <base name="red" displaycolor="#FF0000"/>
                <base name="green" displaycolor="#00FF0080"/>
              </basematerials>
              <m:colorgroup id="6">
                <m:color color="#0000FFFF"/>
                <m:color color="#FFFFFF"/>
              </m:colorgroup>
              <object id="1" pid="5" pindex="1">
                <mesh>
                  <vertices>
                    <vertex x="0" y="0" z="0"/>
                    <vertex x="1" y="0" z="0"/>
                    <vertex x="0" y="1" z="0"/>
                  </vertices>
                  <triangles>
                    <triangle v1="0" v2="1" v3="2"/>
                    <triangle v1="0" v2="1" v3="2" pid="5" p1="0"/>
                    <triangle v1="0" v2="1" v3="2" pid="6" p1="0" p2="1" p3="0"/>
                  </triangles>
                </mesh>
              </object>
              <object id="2">
            """ + Self.triangleMesh + """
              </object>
            </resources>
            <build>
              <item objectid="1"/>
              <item objectid="2"/>
            </build>
            """ + Self.modelEnd))])
        #expect(model.vertexCount == 12)
        #expect(model.hasMaterials)
        let green: [Float] = [0, 1, 0, 128 / 255]
        let red: [Float] = [1, 0, 0, 1]
        let blue: [Float] = [0, 0, 1, 1]
        let white: [Float] = [1, 1, 1, 1]
        let gray: [Float] = [0.8, 0.8, 0.8, 1]
        // A triangle without properties has the object's, and a group's color may differ at each corner.
        let expected = [green, green, green, red, red, red, blue, white, blue, gray, gray, gray]
        let colors = try #require(model.colors)
        for v in 0..<expected.count {
            for c in 0..<4 {
                #expect(abs(expected[v][c] - colors[v * 4 + c]) <= Self.tolerance, "Vertex \(v) component \(c)")
            }
        }
    }

    @Test func textures() throws {
        let texture = Data([1, 2, 3, 4])
        let files: [(String, Data)] = [
            ("3D/3dmodel.model", Self.text(Self.modelStart + """
                <resources>
                  <m:texture2d id="7" path="/3D/Textures/Tex.png" contenttype="image/png"/>
                  <m:texture2dgroup id="8" texid="7">
                    <m:tex2coord u="0.25" v="0.5"/>
                    <m:tex2coord u="1" v="0"/>
                    <m:tex2coord u="0" v="1"/>
                  </m:texture2dgroup>
                  <object id="1">
                    <mesh>
                      <vertices>
                        <vertex x="0" y="0" z="0"/>
                        <vertex x="1" y="0" z="0"/>
                        <vertex x="0" y="1" z="0"/>
                      </vertices>
                      <triangles>
                        <triangle v1="0" v2="1" v3="2" pid="8" p1="0" p2="1" p3="2"/>
                        <triangle v1="0" v2="1" v3="2"/>
                      </triangles>
                    </mesh>
                  </object>
                </resources>
                <build><item objectid="1"/></build>
                """ + Self.modelEnd)),
            // Part names are case-insensitive, and the texture may come after the model.
            ("3D/Textures/tex.png", texture),
        ]
        let model = try Self.load(files)

        // The triangle without a texture comes first.
        #expect(model.parts.count == 2)
        let untextured = model.parts[0]
        let textured = model.parts[1]
        #expect(untextured.material.diffuseTexture == nil)
        #expect(untextured.first == 0)
        #expect(untextured.count == 3)
        #expect(textured.material.diffuseTexture == texture)
        #expect(textured.first == 3)
        #expect(textured.count == 3)

        let expected: [Float] = [0, 0, 0, 0, 0, 0, 0.25, 0.5, 1, 0, 0, 1]
        let texCoords = try #require(model.texCoords)
        for i in 0..<expected.count {
            #expect(abs(expected[i] - texCoords[i]) <= Self.tolerance, "Coordinate \(i)")
        }
        // Without any colors, there are no vertex colors.
        #expect(model.colors == nil)
    }

    @Test func storedEntriesWithDataDescriptors() throws {
        // Like the archives from Bambu Studio, whose uncompressed entries give their sizes only after their data.
        let files: [(String, Data)] = [
            ("Metadata/thumbnail.png", Data(count: 300)),
            ("3D/3dmodel.model", Self.text(Self.modelStart + "<resources><object id=\"1\">" + Self.triangleMesh
                                            + "</object></resources><build><item objectid=\"1\"/></build>" + Self.modelEnd)),
        ]
        let model = try ThreeMfModel(data: TestZipWriter.storedZipWithDataDescriptors(files))
        #expect(model.vertexCount == 3)
        Self.expectPositions(model, 0, [0, 0, 0, 1, 0, 0, 0, 1, 0])
    }

    @Test func zip64Archive() throws {
        let files: [(String, Data)] = [
            ("3D/3dmodel.model", Self.text(Self.modelStart + "<resources><object id=\"1\">" + Self.triangleMesh
                                            + "</object></resources><build><item objectid=\"1\"/></build>" + Self.modelEnd)),
        ]
        let model = try ThreeMfModel(data: TestZipWriter.zip(files, zip64: true))
        #expect(model.vertexCount == 3)
        Self.expectPositions(model, 0, [0, 0, 0, 1, 0, 0, 0, 1, 0])
    }

    @Test func invalidFiles() throws {
        #expect(throws: (any Error).self) { try ThreeMfModel(data: Data("solid cube\nendsolid".utf8)) }
        #expect(throws: (any Error).self) { try Self.load([("Metadata/thumbnail.png", Data(count: 10))]) }
        #expect(throws: (any Error).self) {
            try Self.load([("3D/3dmodel.model", Self.text(Self.modelStart + "<resources>"
                + "<object id=\"1\"><mesh><vertices><vertex x=\"0\" y=\"0\" z=\"0\"/></vertices>"
                + "<triangles><triangle v1=\"0\" v2=\"1\" v3=\"2\"/></triangles></mesh></object>"
                + "</resources><build><item objectid=\"1\"/></build>" + Self.modelEnd))])
        }
        #expect(throws: (any Error).self) {
            try Self.load([("3D/3dmodel.model", Self.text(Self.modelStart
                + "<resources/><build><item objectid=\"9\"/></build>" + Self.modelEnd))])
        }
        #expect(throws: (any Error).self) {
            try Self.load([("3D/3dmodel.model", Self.text(Self.modelStart
                + "<resources><object id=\"1\"><mesh><vertices><vertex x=\"zero\" y=\"0\" z=\"0\"/></vertices>"
                + "</mesh></object></resources>" + Self.modelEnd))])
        }
    }

    // MARK: - Helpers

    private static func text(_ string: String) -> Data {
        Data(string.utf8)
    }

    /// Loads a model from a ZIP archive of the given files, whose entries are deflated (as by ZipOutputStream).
    private static func load(_ files: [(String, Data)]) throws -> ThreeMfModel {
        try ThreeMfModel(data: TestZipWriter.zip(files))
    }

    private static func expectPositions(_ model: ThreeMfModel, _ firstVertex: Int, _ expected: [Float],
                                        sourceLocation: SourceLocation = #_sourceLocation) {
        for i in 0..<expected.count {
            #expect(abs(expected[i] - model.vertices[firstVertex * 3 + i]) <= tolerance, "Coordinate \(i)",
                    sourceLocation: sourceLocation)
        }
    }

    private static func expectNormal(_ model: ThreeMfModel, _ vertex: Int, _ x: Float, _ y: Float, _ z: Float,
                                     sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(x - model.normals[vertex * 3]) <= tolerance, sourceLocation: sourceLocation)
        #expect(abs(y - model.normals[vertex * 3 + 1]) <= tolerance, sourceLocation: sourceLocation)
        #expect(abs(z - model.normals[vertex * 3 + 2]) <= tolerance, sourceLocation: sourceLocation)
    }
}

/// Writes ZIP archives for tests.
enum TestZipWriter {
    /// Writes an archive with deflated entries (or a ZIP64 archive, whose sizes and offsets are in ZIP64 fields).
    static func zip(_ files: [(String, Data)], zip64: Bool = false) -> Data {
        var out = Data()
        var directory = Data()
        for (path, contents) in files {
            let name = Data(path.utf8)
            let compressed = deflate(contents)
            let crc = crc32(contents)
            let offset = out.count
            // Local header: version, flags (UTF-8), deflated, time, date, CRC, and sizes.
            out.appendUInt32(0x04034b50)
            out.appendUInt16(zip64 ? 45 : 20); out.appendUInt16(0x0800); out.appendUInt16(8); out.appendUInt32(0)
            out.appendUInt32(crc)
            if zip64 {
                out.appendUInt32(0xFFFFFFFF); out.appendUInt32(0xFFFFFFFF)
                out.appendUInt16(UInt16(name.count)); out.appendUInt16(20)
                out.append(name)
                out.appendUInt16(0x0001); out.appendUInt16(16)
                out.appendUInt64(UInt64(contents.count)); out.appendUInt64(UInt64(compressed.count))
            } else {
                out.appendUInt32(UInt32(compressed.count)); out.appendUInt32(UInt32(contents.count))
                out.appendUInt16(UInt16(name.count)); out.appendUInt16(0)
                out.append(name)
            }
            out.append(compressed)

            directory.appendUInt32(0x02014b50)
            directory.appendUInt16(zip64 ? 45 : 20); directory.appendUInt16(zip64 ? 45 : 20)
            directory.appendUInt16(0x0800); directory.appendUInt16(8); directory.appendUInt32(0)
            directory.appendUInt32(crc)
            if zip64 {
                directory.appendUInt32(0xFFFFFFFF); directory.appendUInt32(0xFFFFFFFF)
                directory.appendUInt16(UInt16(name.count)); directory.appendUInt16(28)
                directory.appendUInt16(0); directory.appendUInt16(0); directory.appendUInt16(0); directory.appendUInt32(0)
                directory.appendUInt32(0xFFFFFFFF)
                directory.append(name)
                directory.appendUInt16(0x0001); directory.appendUInt16(24)
                directory.appendUInt64(UInt64(contents.count)); directory.appendUInt64(UInt64(compressed.count))
                directory.appendUInt64(UInt64(offset))
            } else {
                directory.appendUInt32(UInt32(compressed.count)); directory.appendUInt32(UInt32(contents.count))
                directory.appendUInt16(UInt16(name.count)); directory.appendUInt16(0)
                directory.appendUInt16(0); directory.appendUInt16(0); directory.appendUInt16(0); directory.appendUInt32(0)
                directory.appendUInt32(UInt32(offset))
                directory.append(name)
            }
        }
        let directoryOffset = out.count
        out.append(directory)
        if zip64 {
            let zip64EndOffset = out.count
            out.appendUInt32(0x06064b50); out.appendUInt64(44)
            out.appendUInt16(45); out.appendUInt16(45); out.appendUInt32(0); out.appendUInt32(0)
            out.appendUInt64(UInt64(files.count)); out.appendUInt64(UInt64(files.count))
            out.appendUInt64(UInt64(directory.count)); out.appendUInt64(UInt64(directoryOffset))
            out.appendUInt32(0x07064b50); out.appendUInt32(0); out.appendUInt64(UInt64(zip64EndOffset)); out.appendUInt32(1)
            out.appendUInt32(0x06054b50); out.appendUInt16(0); out.appendUInt16(0)
            out.appendUInt16(0xFFFF); out.appendUInt16(0xFFFF)
            out.appendUInt32(0xFFFFFFFF); out.appendUInt32(0xFFFFFFFF); out.appendUInt16(0)
        } else {
            out.appendUInt32(0x06054b50); out.appendUInt16(0); out.appendUInt16(0)
            out.appendUInt16(UInt16(files.count)); out.appendUInt16(UInt16(files.count))
            out.appendUInt32(UInt32(directory.count)); out.appendUInt32(UInt32(directoryOffset)); out.appendUInt16(0)
        }
        return out
    }

    /// Writes a ZIP archive with uncompressed entries whose local headers have no sizes or CRCs,
    /// which are given in data descriptors after the data instead (and in the central directory).
    static func storedZipWithDataDescriptors(_ files: [(String, Data)]) -> Data {
        var out = Data()
        var directory = Data()
        for (path, contents) in files {
            let name = Data(path.utf8)
            let crc = crc32(contents)
            let offset = out.count
            // Local header: version, flags (data descriptor, UTF-8), stored, time, date, and no CRC or sizes.
            out.appendUInt32(0x04034b50); out.appendUInt16(20); out.appendUInt16(0x0808); out.appendUInt16(0); out.appendUInt32(0)
            out.appendUInt32(0); out.appendUInt32(0); out.appendUInt32(0)
            out.appendUInt16(UInt16(name.count)); out.appendUInt16(0)
            out.append(name)
            out.append(contents)
            out.appendUInt32(0x08074b50); out.appendUInt32(crc); out.appendUInt32(UInt32(contents.count)); out.appendUInt32(UInt32(contents.count))

            directory.appendUInt32(0x02014b50); directory.appendUInt16(20); directory.appendUInt16(20)
            directory.appendUInt16(0x0808); directory.appendUInt16(0); directory.appendUInt32(0)
            directory.appendUInt32(crc); directory.appendUInt32(UInt32(contents.count)); directory.appendUInt32(UInt32(contents.count))
            directory.appendUInt16(UInt16(name.count)); directory.appendUInt16(0); directory.appendUInt16(0)
            directory.appendUInt16(0); directory.appendUInt16(0); directory.appendUInt32(0); directory.appendUInt32(UInt32(offset))
            directory.append(name)
        }
        let directoryOffset = out.count
        out.append(directory)
        out.appendUInt32(0x06054b50); out.appendUInt16(0); out.appendUInt16(0)
        out.appendUInt16(UInt16(files.count)); out.appendUInt16(UInt16(files.count))
        out.appendUInt32(UInt32(directory.count)); out.appendUInt32(UInt32(directoryOffset)); out.appendUInt16(0)
        return out
    }

    /// Compresses data with raw Deflate (which is what the Compression framework's zlib encoder produces).
    static func deflate(_ data: Data) -> Data {
        if data.isEmpty {
            // An empty final block of fixed Huffman codes.
            return Data([0x03, 0x00])
        }
        let capacity = data.count + 1024
        var output = Data(count: capacity)
        let size = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return output.prefix(size)
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
        }
        return ~crc
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
