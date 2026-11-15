//
//  StlModelTests.swift
//  ModelViewerTests
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
import Testing
@testable import ModelViewer

struct StlModelTests {
    @Test func loadBinaryModel() throws {
        var model = try StlModel(data: try TestResources.data("cube1.stl"))
        #expect(model.vertexCount == 153846)

        model = try StlModel(data: try TestResources.data("bunny.stl"))
        #expect(model.vertexCount == 20898)
        #expect(model.colors == nil)
        #expect(!model.hasMaterials)
    }

    @Test func loadAsciiModel() throws {
        var model = try StlModel(data: try TestResources.data("sample.stl"))
        #expect(model.vertexCount == 24048)

        model = try StlModel(data: try TestResources.data("bottle.stl"))
        #expect(model.vertexCount == 3720)
    }

    @Test func visCamColors() throws {
        // The top bit marks a facet with a color, with 5 bits each of red, green, and blue (from the top).
        let model = try StlModel(data: Self.binaryStl("solid exported", [0x8000 | (31 << 10), 0, 0x8000 | (31 << 5) | 15]))
        #expect(model.hasMaterials)
        Self.expectFacetColor(model, 0, 1, 0, 0)
        // A facet without a color gets the default color.
        Self.expectFacetColor(model, 1, 0.8, 0.8, 0.8)
        Self.expectFacetColor(model, 2, 0, 1, 15 / 31)
    }

    @Test func magicsColors() throws {
        // A header with the object's color, and facets with their own colors (red in the lowest bits),
        // or with the top bit set to use the object's color.
        var header = Self.header("COLOR=", [255, 128, 0, 255])
        var model = try StlModel(data: Self.binaryStl(header, [31, 0x8000, 31 << 10]))
        Self.expectFacetColor(model, 0, 1, 0, 0)
        Self.expectFacetColor(model, 1, 1, 128 / 255, 0)
        Self.expectFacetColor(model, 2, 0, 0, 1)

        // A material's diffuse color takes precedence over the object's color.
        header = Self.header("COLOR=", [255, 0, 0, 255] + Array(",MATERIAL=".utf8) + [0, 0, 255, 255, 1, 1, 1, 1, 2, 2, 2, 2])
        model = try StlModel(data: Self.binaryStl(header, [0x8000]))
        Self.expectFacetColor(model, 0, 0, 0, 1)
    }

    @Test func noColors() throws {
        let model = try StlModel(data: Self.binaryStl("solid exported", [0, 0]))
        #expect(model.colors == nil)
        #expect(!model.hasMaterials)
    }

    @Test func invalidFiles() {
        #expect(throws: (any Error).self) { try StlModel(data: Data()) }
        #expect(throws: (any Error).self) { try StlModel(data: Data(repeating: 0, count: 84)) }
        // A facet count that's larger than the file.
        var truncated = Self.binaryStl("solid exported", [0])
        truncated.removeLast(10)
        #expect(throws: (any Error).self) { try StlModel(data: truncated) }
    }

    private static func expectFacetColor(_ model: MeshModel, _ facet: Int, _ r: Float, _ g: Float, _ b: Float,
                                         sourceLocation: SourceLocation = #_sourceLocation) {
        guard let colors = model.colors else {
            Issue.record("The model has no colors.", sourceLocation: sourceLocation)
            return
        }
        for v in (facet * 3)..<(facet * 3 + 3) {
            #expect(abs(colors[v * 4] - r) < 1e-6, sourceLocation: sourceLocation)
            #expect(abs(colors[v * 4 + 1] - g) < 1e-6, sourceLocation: sourceLocation)
            #expect(abs(colors[v * 4 + 2] - b) < 1e-6, sourceLocation: sourceLocation)
            #expect(colors[v * 4 + 3] == 1, sourceLocation: sourceLocation)
        }
    }

    private static func header(_ text: String, _ extra: [UInt8]) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 80)
        let bytes = Array(text.utf8) + extra
        header.replaceSubrange(0..<bytes.count, with: bytes)
        return header
    }

    private static func binaryStl(_ headerText: String, _ attributes: [Int]) -> Data {
        binaryStl(header(headerText, []), attributes)
    }

    /// Builds a binary STL with a triangle for each of the given facet attributes.
    private static func binaryStl(_ header: [UInt8], _ attributes: [Int]) -> Data {
        var data = Data(header)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(attributes.count))
        for (i, attribute) in attributes.enumerated() {
            let values: [Float] = [0, 0, 1, Float(i), 0, 0, Float(i + 1), 0, 0, Float(i), 1, 0]
            for v in values {
                append(v.bitPattern)
            }
            append(UInt16(truncatingIfNeeded: attribute))
        }
        return data
    }
}
