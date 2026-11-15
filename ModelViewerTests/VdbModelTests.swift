//
//  VdbModelTests.swift
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
import Testing
@testable import ModelViewer

/// Test grids shared by the VDB tests.
enum VdbTestGrids {
    // A sphere centered in the middle of the leaf at the origin, so that the leaf is an interior tile.
    static let center = 3.5
    static let radius = 12.0
    static let voxelSize = 0.5
    static let translation: [Double] = [1, 2, 3]
    static let background = Float(3 * voxelSize)
    static let rootTile = VdbTestWriter.Coord(8192, 0, 0)
    // The color grid is offset by half a voxel from the surface grid, so that its values are interpolated.
    static let colorTranslation: [Double] = [translation[0] + voxelSize / 2, translation[1], translation[2]]
    // The temperature grid is offset by half a voxel along y, so that its values are interpolated.
    static let temperatureTranslation: [Double] = [translation[0], translation[1] + voxelSize / 2, translation[2]]
    static let temperatureCold: Float = 5
    // Flames fill the leaf at this origin, just above the sphere, with this intensity.
    static let flameOrigin = VdbTestWriter.Coord(0, 16, 0)
    static let flameValue: Float = 0.5

    /// Signed distance from the sphere, in world units.
    static func distance(_ x: Int, _ y: Int, _ z: Int) -> Double {
        let dx = Double(x) - center, dy = Double(y) - center, dz = Double(z) - center
        return ((dx * dx + dy * dy + dz * dz).squareRoot() - radius) * voxelSize
    }

    static func levelSetSphere() -> VdbTestWriter.Grid {
        let grid = sphereGrid("sphere", "level set", { x, y, z in
            Float(max(-Double(background), min(Double(background), distance(x, y, z))))
        }, { x, y, z in abs(distance(x, y, z)) < Double(background) })
        grid.background = background
        grid.rootTiles.append((rootTile, -background))
        return grid
    }

    /// The linear color at the given index-space position of the color grid, which varies along each axis.
    static func colorValue(_ index: Double, _ component: Int) -> Float {
        Float((index + 16 + Double(component)) / 40)
    }

    /// A vector grid that covers the sphere, with all voxels active.
    static func colorGrid(_ name: String, _ half: Bool) -> VdbTestWriter.Grid {
        let grid = VdbTestWriter.Grid()
        grid.name = name
        grid.valueType = "vec3s"
        grid.half = half
        grid.scale = [voxelSize, voxelSize, voxelSize]
        grid.translation = colorTranslation
        grid.tiles = constantTiles(0)
        for ox in stride(from: -24, to: 32, by: 8) {
            for oy in stride(from: -24, to: 32, by: 8) {
                for oz in stride(from: -24, to: 32, by: 8) {
                    let leaf = VdbTestWriter.Leaf(components: 3)
                    for i in 0..<512 {
                        let xyz = [ox + (i >> 6), oy + ((i >> 3) & 7), oz + (i & 7)]
                        leaf.active[i] = true
                        for c in 0..<3 {
                            leaf.values[i * 3 + c] = colorValue(Double(xyz[c]), c)
                        }
                    }
                    grid.leaves[VdbTestWriter.Coord(ox, oy, oz)] = leaf
                }
            }
        }
        return grid
    }

    /// The temperature at the given index-space y coordinate of the temperature grid, which rises along the y axis.
    static func temperatureValue(_ y: Double) -> Float {
        Float(Double(temperatureCold) + (y + 24) / 2)
    }

    /// A scalar grid that covers the sphere, with all voxels active, whose temperature rises along the y axis.
    static func temperatureGrid(_ name: String) -> VdbTestWriter.Grid {
        let grid = VdbTestWriter.Grid()
        grid.name = name
        grid.background = temperatureCold
        grid.scale = [voxelSize, voxelSize, voxelSize]
        grid.translation = temperatureTranslation
        grid.tiles = constantTiles(temperatureCold)
        for ox in stride(from: -24, to: 32, by: 8) {
            for oy in stride(from: -24, to: 32, by: 8) {
                for oz in stride(from: -24, to: 32, by: 8) {
                    let leaf = VdbTestWriter.Leaf()
                    for i in 0..<512 {
                        leaf.active[i] = true
                        leaf.values[i] = temperatureValue(Double(oy + ((i >> 3) & 7)))
                    }
                    grid.leaves[VdbTestWriter.Coord(ox, oy, oz)] = leaf
                }
            }
        }
        return grid
    }

    /// A grid of flames, which fill a single leaf at flameOrigin.
    static func flameGrid(_ name: String) -> VdbTestWriter.Grid {
        let grid = VdbTestWriter.Grid()
        grid.name = name
        grid.scale = [voxelSize, voxelSize, voxelSize]
        grid.translation = translation
        grid.tiles = constantTiles(0)
        let leaf = VdbTestWriter.Leaf()
        leaf.values = [Float](repeating: flameValue, count: leaf.values.count)
        leaf.active = [Bool](repeating: true, count: leaf.active.count)
        grid.leaves[flameOrigin] = leaf
        return grid
    }

    static func fogSphere() -> VdbTestWriter.Grid {
        let grid = sphereGrid("fog", "fog volume", { x, y, z in
            Float(max(0, min(1, -distance(x, y, z) / Double(background))))
        }, { x, y, z in distance(x, y, z) < 0 })
        grid.background = 0
        return grid
    }

    /// Builds a grid from the given function, with leaves wherever the values aren't uniform.
    static func sphereGrid(_ name: String, _ gridClass: String, _ value: @escaping (Int, Int, Int) -> Float,
                           _ active: @escaping (Int, Int, Int) -> Bool) -> VdbTestWriter.Grid {
        let grid = VdbTestWriter.Grid()
        grid.name = name
        grid.gridClass = gridClass
        grid.scale = [voxelSize, voxelSize, voxelSize]
        grid.translation = translation
        for ox in stride(from: -24, to: 32, by: 8) {
            for oy in stride(from: -24, to: 32, by: 8) {
                for oz in stride(from: -24, to: 32, by: 8) {
                    let leaf = VdbTestWriter.Leaf()
                    var uniform = true
                    for i in 0..<512 {
                        let x = ox + (i >> 6), y = oy + ((i >> 3) & 7), z = oz + (i & 7)
                        leaf.values[i] = value(x, y, z)
                        leaf.active[i] = active(x, y, z)
                        uniform = uniform && leaf.values[i] == leaf.values[0] && leaf.active[i] == leaf.active[0]
                    }
                    if !uniform {
                        grid.leaves[VdbTestWriter.Coord(ox, oy, oz)] = leaf
                    }
                }
            }
        }
        // Regions without leaves have uniform values, so their value at any point will do.
        grid.tiles = VdbTestWriter.TileFunction(
            value: { x, y, z, _ in value(x, y, z) },
            active: { x, y, z, log2Size in log2Size == 3 && active(x, y, z) })
        return grid
    }

    static func constantTiles(_ value: Float) -> VdbTestWriter.TileFunction {
        VdbTestWriter.TileFunction(value: { _, _, _, _ in value }, active: { _, _, _, _ in false })
    }

    static func read(_ grid: VdbTestWriter.Grid) throws -> VdbGrid {
        try VdbReader(data: VdbTestWriter.write([grid])).readGrid()
    }
}

struct VdbModelTests {
    typealias G = VdbTestGrids

    @Test func levelSetBlosc() throws {
        let grid = G.levelSetSphere()
        let result = try G.read(grid)
        #expect(result.name == "sphere")
        #expect(result.gridClass == "level set")
        #expect(result.isLevelSet)
        #expect(result.background == G.background)
        try assertLeavesEqual(grid, result, false)

        // Values of regions without leaves come from the tiles of the tree.
        #expect(result.tileValue(3, 4, 5) == -G.background)
        #expect(result.tileValue(40, 40, 40) == G.background)
        #expect(result.tileValue(-1000, 0, 0) == G.background)
        #expect(result.tileValue(G.rootTile.x + 100, 5, 5) == -G.background)

        try checkSphereSurface(SurfaceNets(grid: result, isoValue: 0, insideIsAbove: false).extract(),
                               G.radius * G.voxelSize, 0.1, 0.03, 0.99)
    }

    @Test func levelSetBloscWithoutSplitting() throws {
        let grid = G.levelSetSphere()
        grid.bloscSplit = false
        try assertLeavesEqual(grid, G.read(grid), false)
    }

    @Test func levelSetZipHalfFloat() throws {
        let grid = G.levelSetSphere()
        grid.half = true
        grid.compression = VdbTestWriter.compressZip | VdbTestWriter.compressActiveMask
        let result = try G.read(grid)
        try assertLeavesEqual(grid, result, true)
        try checkSphereSurface(SurfaceNets(grid: result, isoValue: 0, insideIsAbove: false).extract(),
                               G.radius * G.voxelSize, 0.1, 0.03, 0.99)
    }

    @Test func levelSetBloscHalfFloat() throws {
        let grid = G.levelSetSphere()
        grid.half = true
        try assertLeavesEqual(grid, G.read(grid), true)
    }

    @Test func levelSetUncompressedDouble() throws {
        let grid = G.levelSetSphere()
        grid.valueType = "double"
        grid.compression = VdbTestWriter.compressNone
        let result = try G.read(grid)
        try assertLeavesEqual(grid, result, false)
        #expect(result.tileValue(40, 40, 40) == G.background)
        try checkSphereSurface(SurfaceNets(grid: result, isoValue: 0, insideIsAbove: false).extract(),
                               G.radius * G.voxelSize, 0.1, 0.03, 0.99)
    }

    @Test func fogVolume() throws {
        let grid = G.fogSphere()
        let result = try G.read(grid)
        #expect(!result.isLevelSet)
        #expect(result.maxValue == 1)
        try assertLeavesEqual(grid, result, false)
        // Interior tiles of a fog volume are active, with full density.
        #expect(result.tileValue(3, 4, 5) == 1)

        // The surface is drawn at 10% of the maximum density, which for this volume is
        // a tenth of the falloff width inside the sphere. The density is clamped to zero outside
        // the sphere, which makes interpolating the surface position and normals less accurate.
        let expectedRadius = G.radius * G.voxelSize - Double(VdbModel.fogIsoFraction * G.background)
        try checkSphereSurface(SurfaceNets(grid: result, isoValue: VdbModel.fogIsoFraction, insideIsAbove: true).extract(),
                               expectedRadius, 0.3, 0.06, 0.8)

        let model = try VdbModel(data: VdbTestWriter.write([grid]))
        #expect(model.gridName == "fog")
        #expect(model.vertexCount > 0)
    }

    @Test func inactiveValueEncodings() throws {
        // Leaves whose inactive values exercise every way that OpenVDB can encode them.
        let bg = G.background
        let inactiveValues: [[Float]] = [
            [bg], [-bg], [0.25], [-bg, bg],
            [0.25, bg], [0.25, 0.5], [0.125, 0.25, 0.375]]
        var random = JavaRandom(1)
        for half in [false, true] {
            let grid = VdbTestWriter.Grid()
            grid.background = bg
            grid.half = half
            grid.tiles = G.constantTiles(bg)
            for n in 0..<inactiveValues.count {
                let leaf = VdbTestWriter.Leaf()
                for i in 0..<512 {
                    leaf.active[i] = random.nextInt(3) == 0
                    leaf.values[i] = leaf.active[i] ? random.nextFloat() - 0.5
                        : inactiveValues[n][random.nextInt(inactiveValues[n].count)]
                }
                grid.leaves[VdbTestWriter.Coord(n * 8, 0, 0)] = leaf
            }
            try assertLeavesEqual(grid, G.read(grid), half)
        }
    }

    @Test func skipsUnsupportedGrids() throws {
        let vectorGrid = VdbTestWriter.Grid()
        vectorGrid.name = "velocity"
        vectorGrid.rawType = "Tree_vec3s_5_4_3"
        vectorGrid.rawPayload = [UInt8](repeating: 0, count: 1000)
        let sphere = G.levelSetSphere()

        let model = try VdbModel(data: VdbTestWriter.write([vectorGrid, sphere]))
        #expect(model.gridName == "sphere")
        #expect(model.vertexCount > 0)
        // A vector grid that isn't named like a color grid isn't used for colors.
        #expect(model.colorGridName == nil)
        #expect(model.colors == nil)
    }

    @Test func colorGrid() throws {
        for half in [false, true] {
            let velocity = G.colorGrid("vel", half)
            let color = G.colorGrid("Cd", half)
            // The color grid may come before or after the surface grid.
            for grids in [[velocity, color, G.levelSetSphere()], [G.levelSetSphere(), velocity, color]] {
                let model = try VdbModel(data: VdbTestWriter.write(grids))
                #expect(model.gridName == "sphere")
                #expect(model.colorGridName == "Cd")
                #expect(model.hasMaterials)

                // Colors are interpolated from the color grid at each vertex, and converted from linear to sRGB.
                let vertices = model.vertices
                let colors = try #require(model.colors)
                let tolerance: Float = half ? 3e-3 : 1e-4
                for v in 0..<model.vertexCount {
                    for c in 0..<3 {
                        let index = (Double(vertices[v * 3 + c]) - G.colorTranslation[c]) / G.voxelSize
                        let expected = VdbModel.linearToSrgb(G.colorValue(index, c))
                        #expect(abs(expected - colors[v * 4 + c]) <= tolerance, "Vertex \(v) component \(c)")
                    }
                    #expect(colors[v * 4 + 3] == 1)
                }
            }
        }
    }

    @Test func temperatureGrid() throws {
        // The temperature grid may come before or after the density grid, and isn't mistaken for it.
        for grids in [[G.temperatureGrid("temperature"), G.fogSphere()],
                      [G.fogSphere(), G.colorGrid("Cd", false), G.temperatureGrid("Temperature")]] {
            let result = try VdbReader(data: VdbTestWriter.write(grids)).read()
            #expect(result.surface.name == "fog")
            let temperature = try #require(result.temperature)
            #expect(temperature.background == G.temperatureCold)
        }

        // Without any other grid, the temperature is shown as the volume.
        let result = try VdbReader(data: VdbTestWriter.write([G.temperatureGrid("temperature")])).read()
        #expect(result.surface.name == "temperature")
        #expect(result.temperature == nil)
    }

    @Test func flameGrid() throws {
        // Grids of flames are named "flames" (EmberGen) or "flame" (Blender).
        for name in ["flames", "Flame"] {
            let result = try VdbReader(data: VdbTestWriter.write(
                [G.flameGrid(name), G.temperatureGrid("temperature"), G.fogSphere()])).read()
            #expect(result.surface.name == "fog")
            #expect(result.flames?.name == name)
            #expect(result.temperature?.name == "temperature")
        }

        // Without any other grid, the flames are shown as the volume.
        let result = try VdbReader(data: VdbTestWriter.write([G.flameGrid("flames")])).read()
        #expect(result.surface.name == "flames")
        #expect(result.flames == nil)
    }

    @Test func noSupportedGrids() {
        let vectorGrid = VdbTestWriter.Grid()
        vectorGrid.rawType = "Tree_vec3s_5_4_3"
        vectorGrid.rawPayload = [UInt8](repeating: 0, count: 100)
        do {
            _ = try VdbReader(data: VdbTestWriter.write([vectorGrid])).readGrid()
            Issue.record("Expected an error")
        } catch {
            #expect(error.localizedDescription.contains("Tree_vec3s_5_4_3"), "\(error.localizedDescription)")
        }
    }

    @Test func invalidFiles() {
        #expect(throws: (any Error).self) { try VdbModel(data: Data("solid cube\nendsolid".utf8)) }
        let valid = VdbTestWriter.write([G.levelSetSphere()])
        let truncated = valid.prefix(valid.count / 2)
        #expect(throws: (any Error).self) { try VdbModel(data: Data(truncated)) }
    }

    @Test func lz4Decompression() throws {
        // Long runs (which need extended length bytes and overlapping matches), and random data.
        var random = JavaRandom(2)
        // An odd size also produces a leftover block.
        var data = [UInt8](repeating: 0, count: 5001)
        for i in 0..<data.count {
            data[i] = i < 2000 ? UInt8(i / 700) : i < 3000 ? UInt8(i % 7) : UInt8(random.nextInt(256))
        }
        for split in [false, true] {
            let compressed = VdbTestWriter.bloscCompress(data, 4, split)
            #expect(compressed.count < data.count)
            var output = [UInt8](repeating: 0, count: data.count)
            try Blosc().decompress(compressed, compressed.count, &output, output.count)
            #expect(output == data)
        }
    }

    private func assertLeavesEqual(_ expected: VdbTestWriter.Grid, _ actual: VdbGrid, _ half: Bool) throws {
        #expect(expected.leaves.count == actual.leaves.count)
        for (o, leaf) in expected.leaves {
            let values = try #require(actual.leaves[VdbGrid.packKey(o.x >> 3, o.y >> 3, o.z >> 3)], "Missing leaf \(o)")
            var mismatches = 0
            for i in 0..<512 {
                // Inactive values are usually stored at full precision, even in half-float grids.
                // (The test values are chosen so that they're exact either way.)
                let expectedValue = half && leaf.active[i]
                    ? VdbReader.halfToFloat(Int(VdbTestWriter.floatToHalf(leaf.values[i])))
                    : leaf.values[i]
                if expectedValue != values[i] {
                    mismatches += 1
                    if mismatches <= 5 {
                        Issue.record("Leaf \(o) voxel \(i): expected \(expectedValue), got \(values[i])")
                    }
                }
            }
        }
    }

    /// Checks that the mesh is a closed, consistently oriented surface that faces outward,
    /// and that it matches a sphere of the given radius (in world units), within the given
    /// tolerance for vertex positions (in voxels) and for the enclosed volume (as a fraction).
    /// Vertex normals must point outward, with at least the given cosine to the radial direction.
    private func checkSphereSurface(_ mesh: SurfaceNets.Mesh, _ radius: Double, _ tolerance: Double, _ volumeTolerance: Double,
                                    _ minNormalCosine: Double) throws {
        let v = mesh.vertices
        let n = mesh.normals
        let indices = mesh.indices
        #expect(mesh.vertexCount > 1000)
        #expect(mesh.indexCount % 3 == 0)

        let cx = G.center * G.voxelSize + G.translation[0]
        let cy = G.center * G.voxelSize + G.translation[1]
        let cz = G.center * G.voxelSize + G.translation[2]
        var failures = 0
        for i in 0..<mesh.vertexCount {
            let dx = Double(v[i * 3]) - cx, dy = Double(v[i * 3 + 1]) - cy, dz = Double(v[i * 3 + 2]) - cz
            let r = (dx * dx + dy * dy + dz * dz).squareRoot()
            let cosine = (Double(n[i * 3]) * dx + Double(n[i * 3 + 1]) * dy + Double(n[i * 3 + 2]) * dz) / r
            if abs(r - radius) > tolerance * G.voxelSize || !(cosine > minNormalCosine) {
                failures += 1
                if failures <= 5 {
                    Issue.record("Vertex \(i): distance from center \(r), expected \(radius); normal cosine \(cosine)")
                }
            }
        }

        // Every edge must be shared by exactly two triangles, in opposite directions.
        var edges = Set<UInt64>()
        var volume = 0.0
        var i = 0
        while i < mesh.indexCount {
            for e in 0..<3 {
                let key = (UInt64(indices[i + e]) << 32) | UInt64(indices[i + (e + 1) % 3])
                let inserted = edges.insert(key).inserted
                if !inserted {
                    Issue.record("Duplicate edge")
                    return
                }
            }
            let a = Int(indices[i]) * 3, b = Int(indices[i + 1]) * 3, c = Int(indices[i + 2]) * 3
            func p(_ k: Int, _ center: Double) -> Double { Double(v[k]) - center }
            volume += p(a, cx) * (p(b + 1, cy) * p(c + 2, cz) - p(b + 2, cz) * p(c + 1, cy))
                - p(a + 1, cy) * (p(b, cx) * p(c + 2, cz) - p(b + 2, cz) * p(c, cx))
                + p(a + 2, cz) * (p(b, cx) * p(c + 1, cy) - p(b + 1, cy) * p(c, cx))
            i += 3
        }
        for key in edges {
            let reverse = (key << 32) | (key >> 32)
            if !edges.contains(reverse) {
                Issue.record("Unmatched edge")
                return
            }
        }
        // A positive volume means that the triangles wind counterclockwise when viewed from outside.
        volume /= 6
        let expectedVolume = 4.0 / 3.0 * Double.pi * radius * radius * radius
        #expect(abs(volume - expectedVolume) <= expectedVolume * volumeTolerance, "Volume \(volume), expected \(expectedVolume)")
    }
}
