//
//  VolumeTextureTests.swift
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
import simd
@testable import ModelViewer

struct VolumeTextureTests {
    typealias G = VdbTestGrids

    // The fog sphere has density wherever it's less than RADIUS voxels from its center, which on
    // each axis is between these index coordinates.
    private static let minIndex = -8
    private static let maxIndex = 15
    // Allows for the rounding of values to bytes.
    private static let byteTolerance = 0.501

    private func near(_ expected: Double, _ actual: Int, _ tolerance: Double = byteTolerance) -> Bool {
        abs(expected - Double(actual)) <= tolerance
    }

    @Test func fullResolution() throws {
        let texture = try build(VolumeTexture.maxBytes, G.fogSphere())
        #expect(texture.factor == 1)
        // An empty texel of padding on each side.
        let size = Self.maxIndex - Self.minIndex + 3
        assertSize(texture, size)
        #expect(texture.origin == [Self.minIndex - 1, Self.minIndex - 1, Self.minIndex - 1])
        #expect(texture.maxDensity == 1)
        #expect(texture.channels == 2)
        #expect(texture.glow == .none)
        #expect(texture.color == nil)

        // This includes the middle of the sphere, which is a tile rather than a leaf.
        var failures = 0
        for k in 0..<size {
            for j in 0..<size {
                for i in 0..<size {
                    let x = Self.minIndex - 1 + i, y = Self.minIndex - 1 + j, z = Self.minIndex - 1 + k
                    if !near(fogDensity(x, y, z) * 255, density(texture, i, j, k)) {
                        failures += 1
                        if failures <= 5 { Issue.record("Texel \(i),\(j),\(k)") }
                    }
                }
            }
        }
        checkLight(texture)
        checkTexelPositions(texture)

        // The sphere is symmetric, so its center of mass is its center.
        for c in 0..<3 {
            #expect(abs(G.center * G.voxelSize + G.translation[c] - texture.centroid[c]) <= 1e-6)
        }
    }

    @Test func reducedResolution() throws {
        // Too large at full resolution (26^3 texels, with 2 bytes each), but not at half of it.
        let texture = try build(30000, G.fogSphere())
        #expect(texture.factor == 2)
        let lo = (Self.minIndex >> 1) - 1
        let size = (Self.maxIndex >> 1) + 1 - lo + 1
        assertSize(texture, size)
        #expect(texture.origin == [lo * 2, lo * 2, lo * 2])
        // The middle of the sphere has the full density.
        #expect(texture.maxDensity == 1)

        // Each texel has the average density of the 2x2x2 voxels that it covers.
        var failures = 0
        for k in 0..<size {
            for j in 0..<size {
                for i in 0..<size {
                    var sum = 0.0
                    for n in 0..<8 {
                        sum += fogDensity((lo + i) * 2 + (n & 1), (lo + j) * 2 + ((n >> 1) & 1), (lo + k) * 2 + ((n >> 2) & 1))
                    }
                    if !near(sum / 8 * 255, density(texture, i, j, k)) {
                        failures += 1
                        if failures <= 5 { Issue.record("Texel \(i),\(j),\(k)") }
                    }
                }
            }
        }
        checkLight(texture)
        checkTexelPositions(texture)
    }

    @Test func downsampled() throws {
        let full = try build(VolumeTexture.maxBytes, G.fogSphere(), G.colorGrid("Cd", false), G.temperatureGrid("temperature"))
        let half = full.downsampled()
        #expect(half.factor == 2)
        #expect(half.channels == 3)
        assertSize(half, (full.sizeX + 1) / 2)
        #expect(full.origin == half.origin)
        #expect(full.centroid == half.centroid)

        // Each texel has the average density, light, temperature, and (linear) color of the 2x2x2
        // texels that it covers.
        var failures = 0
        for k in 0..<half.sizeZ {
            for j in 0..<half.sizeY {
                for i in 0..<half.sizeX {
                    var sum = [0.0, 0.0, 0.0]
                    var color = [0.0, 0.0, 0.0]
                    for n in 0..<8 {
                        let fi = i * 2 + (n & 1), fj = j * 2 + ((n >> 1) & 1), fk = k * 2 + ((n >> 2) & 1)
                        for c in 0..<3 {
                            sum[c] += Double(channel(full, fi, fj, fk, c))
                            color[c] += srgbToLinear(Double(self.color(full, fi, fj, fk, c)) / 255)
                        }
                    }
                    for c in 0..<3 {
                        let ok = near(sum[c] / 8, channel(half, i, j, k, c)) &&
                            near(Double(VdbModel.linearToSrgb(Float(color[c] / 8)) * 255), self.color(half, i, j, k, c))
                        if !ok {
                            failures += 1
                            if failures <= 5 { Issue.record("Texel \(i),\(j),\(k) component \(c)") }
                        }
                    }
                }
            }
        }
        checkTexelPositions(half)
    }

    @Test func color() throws {
        let texture = try build(VolumeTexture.maxBytes, G.fogSphere(), G.colorGrid("Cd", false))
        #expect(texture.factor == 1)
        #expect(texture.color != nil)
        let size = texture.sizeX
        var failures = 0
        for k in 0..<size {
            for j in 0..<size {
                for i in 0..<size {
                    let index = [Self.minIndex - 1 + i, Self.minIndex - 1 + j, Self.minIndex - 1 + k]
                    let density = Double(self.density(texture, i, j, k)) / 255
                    for c in 0..<3 {
                        // Colors are interpolated from the color grid at each texel, and premultiplied by the density.
                        let colorIndex = (Double(index[c]) * G.voxelSize + G.translation[c] - G.colorTranslation[c]) / G.voxelSize
                        let expected = density == 0 ? 0
                            : Double(VdbModel.linearToSrgb(Float(Double(G.colorValue(colorIndex, c)) * density)) * 255)
                        if !near(expected, color(texture, i, j, k, c)) {
                            failures += 1
                            if failures <= 5 { Issue.record("Texel \(i),\(j),\(k) component \(c)") }
                        }
                    }
                }
            }
        }
    }

    @Test func temperature() throws {
        let plain = try build(VolumeTexture.maxBytes, G.fogSphere())
        let texture = try build(VolumeTexture.maxBytes, G.fogSphere(), G.temperatureGrid("temperature"))
        #expect(texture.channels == 3)
        #expect(texture.glow == .thermal)
        #expect(texture.color == nil)
        let size = texture.sizeX
        assertSize(texture, size)
        #expect(plain.sizeX == size)
        let hottest = G.temperatureValue(31)
        var failures = 0
        for k in 0..<size {
            for j in 0..<size {
                for i in 0..<size {
                    // The density and light are the same as without a temperature.
                    var ok = density(plain, i, j, k) == density(texture, i, j, k) && light(plain, i, j, k) == light(texture, i, j, k)
                    // Temperatures are interpolated from the temperature grid at each texel with any
                    // density, as a fraction of the way from cold to the hottest.
                    let temperatureIndex = Double(Self.minIndex - 1 + j) - 0.5
                    let expected = density(texture, i, j, k) == 0 ? 0
                        : Double((G.temperatureValue(temperatureIndex) - G.temperatureCold) / (hottest - G.temperatureCold) * 255)
                    ok = ok && near(expected, channel(texture, i, j, k, 2))
                    if !ok {
                        failures += 1
                        if failures <= 5 { Issue.record("Texel \(i),\(j),\(k)") }
                    }
                }
            }
        }

        // A temperature grid that's cold everywhere is left out.
        let cold = G.temperatureGrid("temperature")
        for leaf in cold.leaves.values {
            leaf.values = [Float](repeating: G.temperatureCold - 1, count: leaf.values.count)
        }
        let coldTexture = try build(VolumeTexture.maxBytes, G.fogSphere(), cold)
        #expect(coldTexture.channels == 2)
        #expect(coldTexture.glow == .none)
    }

    @Test func flames() throws {
        let plain = try build(VolumeTexture.maxBytes, G.fogSphere())
        let texture = try build(VolumeTexture.maxBytes, G.fogSphere(), G.flameGrid("flames"))
        #expect(texture.glow == .flame)
        #expect(texture.channels == 3)
        // The texture extends upward to include the flames, which are above the sphere.
        let top = G.flameOrigin.y + 7
        #expect(plain.origin == texture.origin)
        #expect(plain.sizeX == texture.sizeX)
        #expect(top - (Self.minIndex - 1) + 2 == texture.sizeY)
        #expect(plain.sizeZ == texture.sizeZ)

        var failures = 0
        for k in 0..<texture.sizeZ {
            for j in 0..<texture.sizeY {
                for i in 0..<texture.sizeX {
                    let density = j < plain.sizeY ? self.density(plain, i, j, k) : 0
                    // Flames are sampled even where there is no density.
                    let x = Self.minIndex - 1 + i - G.flameOrigin.x, y = Self.minIndex - 1 + j - G.flameOrigin.y,
                        z = Self.minIndex - 1 + k - G.flameOrigin.z
                    let inFlames = x >= 0 && x < 8 && y >= 0 && y < 8 && z >= 0 && z < 8
                    if density != self.density(texture, i, j, k) || channel(texture, i, j, k, 2) != (inFlames ? 255 : 0) {
                        failures += 1
                        if failures <= 5 { Issue.record("Texel \(i),\(j),\(k)") }
                    }
                }
            }
        }
        // The flames would fill a cube of 8 voxels on each side, at full intensity.
        #expect(abs(texture.flameLength - 8 * G.voxelSize) <= 1e-9)
    }

    @Test func flamesWithoutDensity() throws {
        let empty = VdbTestWriter.Grid()
        empty.name = "density"
        empty.gridClass = "fog volume"
        empty.scale = [G.voxelSize, G.voxelSize, G.voxelSize]
        empty.translation = G.translation
        empty.tiles = G.constantTiles(0)
        empty.leaves[VdbTestWriter.Coord(0, 0, 0)] = VdbTestWriter.Leaf()
        let texture = try build(VolumeTexture.maxBytes, empty, G.flameGrid("flames"))
        #expect(texture.glow == .flame)
        #expect(texture.maxDensity == 0)
        assertSize(texture, 10)
        let flameOrigin = [G.flameOrigin.x, G.flameOrigin.y, G.flameOrigin.z]
        for c in 0..<3 {
            #expect(texture.origin[c] == flameOrigin[c] - 1)
            // Without any density, the center of the volume is the center of the flames.
            #expect(abs((Double(flameOrigin[c]) + 3.5) * G.voxelSize + G.translation[c] - texture.centroid[c]) <= 1e-9)
        }
    }

    @Test func emptyOrTooLarge() throws {
        let empty = VdbTestWriter.Grid()
        empty.gridClass = "fog volume"
        empty.tiles = G.constantTiles(0)
        empty.leaves[VdbTestWriter.Coord(0, 0, 0)] = VdbTestWriter.Leaf()
        #expect(VolumeTexture.build(grid: try G.read(empty), colorGrid: nil, glowGrid: nil, glowKind: .none,
                                    maxBytes: VolumeTexture.maxBytes) == nil)

        // Too large even at an eighth of the resolution (5^3 texels).
        #expect(VolumeTexture.build(grid: try G.read(G.fogSphere()), colorGrid: nil, glowGrid: nil, glowKind: .none,
                                    maxBytes: 100) == nil)
    }

    @Test func loader() throws {
        let fog = try #require(try load(G.fogSphere()) as? VdbVolumeModel)
        #expect(fog.gridName == "fog")
        #expect(fog.colorGridName == nil)
        #expect(fog.glowGridName == nil)

        let coloredFire = try #require(try load(G.fogSphere(), G.colorGrid("Cd", false), G.temperatureGrid("temperature")) as? VdbVolumeModel)
        #expect(coloredFire.colorGridName == "Cd")
        #expect(coloredFire.glowGridName == "temperature")

        // The temperature glows rather than flames, if there are both.
        let fire = try #require(try load(G.fogSphere(), G.temperatureGrid("temperature"), G.flameGrid("flames")) as? VdbVolumeModel)
        #expect(fire.glowGridName == "temperature")
        let flames = try #require(try load(G.fogSphere(), G.flameGrid("flames")) as? VdbVolumeModel)
        #expect(flames.glowGridName == "flames")

        let levelSet = try #require(try load(G.levelSetSphere()) as? VdbModel)
        #expect(levelSet.gridName == "sphere")
    }

    @Test func blackbodyColor() {
        // Compared to Mitchell Charity's table of blackbody colors (CIE 1931 2-degree observer, sRGB).
        assertSrgbEquals([255, 137, 18], VolumeTexture.blackbodyColor(2000), 8)
        assertSrgbEquals([255, 180, 107], VolumeTexture.blackbodyColor(3000), 8)
        // The white point of sRGB is about 6500K.
        assertSrgbEquals([255, 255, 255], VolumeTexture.blackbodyColor(6500), 8)

        // Hotter is less red.
        var previous: [Float]?
        for kelvin in stride(from: 800, through: 3000, by: 100) {
            let color = VolumeTexture.blackbodyColor(Double(kelvin))
            #expect(color[0] == 1)
            if let previous {
                #expect(color[1] > previous[1], "Green at \(kelvin)K")
                #expect(color[2] >= previous[2], "Blue at \(kelvin)K")
            }
            previous = color
        }
    }

    @Test func fireRamp() {
        let ramp = VolumeTexture.fireRamp
        #expect(ramp.count == 256 * 3)
        // The colors of blackbodies from the coolest to the hottest, at full brightness.
        for i in stride(from: 0, to: 256, by: 51) {
            let color = VolumeTexture.blackbodyColor(VolumeTexture.fireMinKelvin
                + Double(i) / 255 * (VolumeTexture.fireMaxKelvin - VolumeTexture.fireMinKelvin))
            for c in 0..<3 {
                #expect(near(Double(VdbModel.linearToSrgb(color[c]) * 255), Int(ramp[i * 3 + c])), "Entry \(i)")
            }
        }
        for i in 1..<256 {
            #expect(ramp[i * 3] == 255, "Entry \(i)")
            #expect(ramp[i * 3 + 1] >= ramp[i * 3 - 2], "Entry \(i)")
        }
    }

    @Test func cube() {
        // Every triangle of the cube must face outward, and together they must cover all six faces.
        let v = VdbVolumeModel.cubeVertices
        #expect(v.count == 36 * 3)
        var area = 0.0
        for t in stride(from: 0, to: v.count, by: 9) {
            var e1 = [0.0, 0.0, 0.0], e2 = [0.0, 0.0, 0.0], center = [0.0, 0.0, 0.0]
            for c in 0..<3 {
                e1[c] = Double(v[t + 3 + c] - v[t + c])
                e2[c] = Double(v[t + 6 + c] - v[t + c])
                center[c] = Double(v[t + c] + v[t + 3 + c] + v[t + 6 + c]) / 3 - 0.5
            }
            let normal = [e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]]
            #expect(normal[0] * center[0] + normal[1] * center[1] + normal[2] * center[2] > 0, "Triangle \(t / 9) faces inward")
            area += (normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2]).squareRoot() / 2
        }
        #expect(abs(area - 6) <= 1e-6)
    }

    @Test func volumeModelBounds() {
        // The model's bounds are the corners of the texture's box, and its center is the centroid.
        let texture = VolumeTexture.build(grid: try! G.read(G.fogSphere()), colorGrid: nil, glowGrid: nil, glowKind: .none,
                                          maxBytes: VolumeTexture.maxBytes)!
        let model = VdbVolumeModel(volume: texture, gridName: "fog", colorGridName: nil, glowGridName: nil)
        let corner0 = VolumeTexture.transform(texture.textureToWorld, 0, 0, 0)
        let corner1 = VolumeTexture.transform(texture.textureToWorld, 1, 1, 1)
        #expect(abs(Double(model.minX) - corner0[0]) < 1e-4 && abs(Double(model.maxY) - corner1[1]) < 1e-4)
        #expect(abs(Double(model.centerMassZ) - texture.centroid[2]) < 1e-4)
        let p = model.textureMatrix * SIMD4<Float>(1, 1, 1, 1)
        #expect(abs(Double(p.x) - corner1[0]) < 1e-4 && abs(Double(p.z) - corner1[2]) < 1e-4)
        #expect(!model.isMirrored)
    }

    /// Checks that the light in each texel is the light from above, attenuated by the density of
    /// the texels above it, and by half of its own.
    private func checkLight(_ texture: VolumeTexture) {
        let step = Double(VolumeTexture.extinctionScale) * Double(texture.maxDensity) * G.voxelSize * Double(texture.factor) / 255
        var failures = 0
        for k in 0..<texture.sizeZ {
            for i in 0..<texture.sizeX {
                var opticalDepth = 0.0
                for j in stride(from: texture.sizeY - 1, through: 0, by: -1) {
                    let density = Double(self.density(texture, i, j, k)) * step
                    if !near(exp(-(opticalDepth + density / 2)) * 255, light(texture, i, j, k)) {
                        failures += 1
                        if failures <= 5 { Issue.record("Light of texel \(i),\(j),\(k)") }
                    }
                    opticalDepth += density
                }
            }
        }
    }

    /// Checks that texture coordinates map to the world positions of the voxels that the texels cover.
    private func checkTexelPositions(_ texture: VolumeTexture) {
        let size = [texture.sizeX, texture.sizeY, texture.sizeZ]
        let texels = [[0, 0, 0], [size[0] - 1, size[1] - 1, size[2] - 1], [size[0] / 2, 1, size[2] - 2]]
        for texel in texels {
            let position = VolumeTexture.transform(texture.textureToWorld,
                                                   (Double(texel[0]) + 0.5) / Double(size[0]),
                                                   (Double(texel[1]) + 0.5) / Double(size[1]),
                                                   (Double(texel[2]) + 0.5) / Double(size[2]))
            for c in 0..<3 {
                // The center of the texel's voxels.
                let index = Double(texture.origin[c] + texel[c] * texture.factor) + Double(texture.factor - 1) / 2
                #expect(abs(index * G.voxelSize + G.translation[c] - position[c]) <= 1e-9)
            }
        }
    }

    private func assertSrgbEquals(_ expected: [Int], _ linear: [Float], _ tolerance: Double) {
        for c in 0..<3 {
            #expect(abs(Double(expected[c]) - Double(VdbModel.linearToSrgb(linear[c]) * 255)) <= tolerance, "Component \(c)")
        }
    }

    private func fogDensity(_ x: Int, _ y: Int, _ z: Int) -> Double {
        max(0, min(1, -G.distance(x, y, z) / Double(G.background)))
    }

    private func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private func density(_ texture: VolumeTexture, _ i: Int, _ j: Int, _ k: Int) -> Int {
        channel(texture, i, j, k, 0)
    }

    private func light(_ texture: VolumeTexture, _ i: Int, _ j: Int, _ k: Int) -> Int {
        channel(texture, i, j, k, 1)
    }

    private func channel(_ texture: VolumeTexture, _ i: Int, _ j: Int, _ k: Int, _ channel: Int) -> Int {
        Int(texture.texels[index(texture, i, j, k) * texture.channels + channel])
    }

    private func color(_ texture: VolumeTexture, _ i: Int, _ j: Int, _ k: Int, _ component: Int) -> Int {
        Int(texture.color![index(texture, i, j, k) * 3 + component])
    }

    private func index(_ texture: VolumeTexture, _ i: Int, _ j: Int, _ k: Int) -> Int {
        (k * texture.sizeY + j) * texture.sizeX + i
    }

    private func assertSize(_ texture: VolumeTexture, _ size: Int) {
        #expect(texture.sizeX == size)
        #expect(texture.sizeY == size)
        #expect(texture.sizeZ == size)
    }

    /// Builds the texture of the first grid, along with the color, temperature, and flame grids among the others.
    private func build(_ maxBytes: Int, _ grids: VdbTestWriter.Grid...) throws -> VolumeTexture {
        let result = try VdbReader(data: VdbTestWriter.write(grids)).read()
        #expect(grids[0].name == result.surface.name)
        let glowGrid = result.flames ?? result.temperature
        let glowKind: VolumeTexture.Glow = result.flames != nil ? .flame : .thermal
        return try #require(VolumeTexture.build(grid: result.surface, colorGrid: result.color, glowGrid: glowGrid,
                                                glowKind: glowKind, maxBytes: maxBytes))
    }

    private func load(_ grids: VdbTestWriter.Grid...) throws -> Model {
        try VdbLoader.load(data: VdbTestWriter.write(grids))
    }
}
