//
//  VolumeTexture.swift
//  ModelViewer
//
//  The density of a fog volume, resampled into a dense 3D texture for rendering, along with the
//  light that reaches each texel from above, and the volume's colors and glow, if it has them.
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

final class VolumeTexture: @unchecked Sendable {
    let sizeX: Int
    let sizeY: Int
    let sizeZ: Int
    /// Index coordinates of the first voxel that the first texel covers.
    let origin: [Int]
    /// Number of voxels along each side of a texel.
    let factor: Int
    /// Index-to-world transform of the grid, as in `VdbGrid.transform`.
    let gridTransform: [Double]
    /// The density of a texel whose stored density is at its maximum (255).
    let maxDensity: Float
    /// How the volume glows, if it does.
    let glow: Glow
    /// For flames, the size of a cube that would hold all of their glow at full intensity, in world
    /// units, by which the brightness of flames is scaled, so that it doesn't depend on the units.
    let flameLength: Double
    /// Texels ordered by x, then y, then z (x varies fastest), with `channels` bytes each: the
    /// density, as a fraction of `maxDensity`, the fraction of the light from above that reaches
    /// the texel, and how much it glows, if the volume does: a fraction of the way from the
    /// background of the glow grid (e.g. cold) to its highest value (e.g. the hottest temperature).
    let texels: [UInt8]
    /// Optional sRGB color of each texel (three bytes), premultiplied by its density fraction.
    let color: [UInt8]?
    /// Density-weighted center of the volume, in world coordinates.
    let centroid: [Double]

    /// Transform from texture coordinates (0 to 1 across the whole texture) to world coordinates,
    /// as a 4x3 affine matrix applied to row vectors, like `VdbGrid.transform`. (Equivalently, the
    /// first nine values are the column-major 3x3 linear part, and the last three the translation.)
    let textureToWorld: [Double]

    /// Number of bytes per texel in `texels`.
    var channels: Int { glow == .none ? 2 : 3 }

    /// How a volume glows.
    enum Glow: Sendable {
        case none
        /// By its temperature, as much as it absorbs light (like the soot of fire), by Kirchhoff's law.
        case thermal
        /// With flames, which glow on their own, even where there's no density.
        case flame
    }

    init(sizeX: Int, sizeY: Int, sizeZ: Int, origin: [Int], factor: Int, gridTransform: [Double], maxDensity: Float,
         glow: Glow, flameLength: Double, texels: [UInt8], color: [UInt8]?, centroid: [Double]) {
        self.sizeX = sizeX
        self.sizeY = sizeY
        self.sizeZ = sizeZ
        self.origin = origin
        self.factor = factor
        self.gridTransform = gridTransform
        self.maxDensity = maxDensity
        self.glow = glow
        self.flameLength = flameLength
        self.texels = texels
        self.color = color
        self.centroid = centroid
        self.textureToWorld = Self.computeTextureToWorld([sizeX, sizeY, sizeZ], origin, factor, gridTransform)
    }

    /// Returns this texture at half its resolution.
    func downsampled() -> VolumeTexture {
        let newSizeX = (sizeX + 1) / 2
        let newSizeY = (sizeY + 1) / 2
        let newSizeZ = (sizeZ + 1) / 2
        let channels = self.channels
        var newTexels = [UInt8](repeating: 0, count: newSizeX * newSizeY * newSizeZ * channels)
        var newColor = color.map { _ in [UInt8](repeating: 0, count: newSizeX * newSizeY * newSizeZ * 3) }
        var sum = [Int](repeating: 0, count: channels)
        var colorSum = SIMD3<Float>(0, 0, 0)
        let srgbToLinear = Self.srgbToLinear
        for z in 0..<newSizeZ {
            for y in 0..<newSizeY {
                for x in 0..<newSizeX {
                    for c in 0..<channels { sum[c] = 0 }
                    colorSum = SIMD3(0, 0, 0)
                    for n in 0..<8 {
                        let sx = x * 2 + (n & 1)
                        let sy = y * 2 + ((n >> 1) & 1)
                        let sz = z * 2 + ((n >> 2) & 1)
                        if sx >= sizeX || sy >= sizeY || sz >= sizeZ {
                            // Texels beyond the edges are empty and cold, and fully lit.
                            sum[1] += 255
                            continue
                        }
                        let i = (sz * sizeY + sy) * sizeX + sx
                        for c in 0..<channels {
                            sum[c] += Int(texels[i * channels + c])
                        }
                        if let color {
                            for c in 0..<3 {
                                colorSum[c] += srgbToLinear[Int(color[i * 3 + c])]
                            }
                        }
                    }
                    let i = (z * newSizeY + y) * newSizeX + x
                    for c in 0..<channels {
                        newTexels[i * channels + c] = Self.toByte(Float(sum[c]) / 8)
                    }
                    if newColor != nil {
                        for c in 0..<3 {
                            newColor![i * 3 + c] = Self.toByte(VdbModel.linearToSrgb(colorSum[c] / 8) * 255)
                        }
                    }
                }
            }
        }
        return VolumeTexture(sizeX: newSizeX, sizeY: newSizeY, sizeZ: newSizeZ, origin: origin, factor: factor * 2,
                             gridTransform: gridTransform, maxDensity: maxDensity, glow: glow, flameLength: flameLength,
                             texels: newTexels, color: newColor, centroid: centroid)
    }

    // MARK: - Constants

    /// Extinction coefficient (per world unit) of a density of 1, which is the usual convention
    /// for fog volumes (as in Houdini and Blender).
    static let extinctionScale: Float = 1

    /// Maximum size of the texture data, including the colors.
    static let maxBytes = 64 << 20

    /// Maximum number of texels along each side, which nearly all GPUs support for 3D textures.
    static let maxDimension = 2048

    /// Empty texels around the volume, so that its density fades to nothing at the edges of the texture.
    private static let padding = 1

    /// Range of blackbody temperatures (in Kelvin) that the temperature of fire is shown with.
    static let fireMinKelvin = 800.0
    static let fireMaxKelvin = 2500.0

    private static let rounding = 1e-6

    /// Second radiation constant of Planck's law (hc/k), in meter-Kelvins.
    private static let planckC2 = 1.4388e-2

    /// Colors of fire for temperatures from cold to the hottest (256 entries of three sRGB
    /// bytes): the color of a blackbody from `fireMinKelvin` to `fireMaxKelvin`, at full
    /// brightness. (How brightly each temperature glows is up to the renderer.)
    static let fireRamp: [UInt8] = {
        var ramp = [UInt8](repeating: 0, count: 256 * 3)
        for i in 0..<256 {
            let color = blackbodyColor(fireMinKelvin + Double(i) / 255 * (fireMaxKelvin - fireMinKelvin))
            for c in 0..<3 {
                ramp[i * 3 + c] = toByte(VdbModel.linearToSrgb(color[c]) * 255)
            }
        }
        return ramp
    }()

    private static let srgbToLinear: [Float] = (0..<256).map {
        let c = Float($0) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    // MARK: - Building

    /// Resamples the density of a fog volume (and its color grid and a grid that makes it glow,
    /// if any) at the highest resolution that fits within the given number of bytes. Returns
    /// nil if the volume has no density or flames at all, or if it's too large even at the
    /// lowest resolution.
    static func build(grid: VdbGrid, colorGrid: VdbGrid?, glowGrid: VdbGrid?, glowKind: Glow, maxBytes: Int) -> VolumeTexture? {
        // A glow grid that's cold everywhere doesn't make anything glow.
        let hottest = glowGrid.map { maxValue($0) } ?? 0
        let glow: Glow = if let glowGrid, hottest > glowGrid.background { glowKind } else { .none }

        // Find the extent of the voxels that have any density, and of any flames, which glow
        // even where there's no density.
        var min = [Int](repeating: Int.max, count: 3)
        var max = [Int](repeating: Int.min, count: 3)
        includeValuesAbove(grid, 0, &min, &max)
        var flameMin = [Int](repeating: Int.max, count: 3)
        var flameMax = [Int](repeating: Int.min, count: 3)
        if glow == .flame, let glowGrid {
            includeOtherGrid(glowGrid, grid, &flameMin, &flameMax)
            include(&min, &max, flameMin[0], flameMin[1], flameMin[2])
            include(&min, &max, flameMax[0], flameMax[1], flameMax[2])
        }
        if min[0] > max[0] {
            return nil
        }

        // Reduce the resolution by powers of two until the texture fits. Texels then never
        // straddle leaves, so the density of each one can be averaged from a single leaf.
        let channels = glow == .none ? 2 : 3
        let bytesPerTexel = channels + (colorGrid != nil ? 3 : 0)
        let leafLog2 = grid.leafLog2
        var log2Factor = 0
        var lo = [0, 0, 0]
        var size = [0, 0, 0]
        while true {
            for a in 0..<3 {
                lo[a] = (min[a] >> log2Factor) - padding
                size[a] = (max[a] >> log2Factor) + padding - lo[a] + 1
            }
            if size.allSatisfy({ $0 <= maxDimension }) && size[0] * size[1] * size[2] * bytesPerTexel <= maxBytes {
                break
            }
            if log2Factor == leafLog2 {
                return nil
            }
            log2Factor += 1
        }
        let factor = 1 << log2Factor
        let sizeX = size[0], sizeY = size[1], sizeZ = size[2]

        // Store densities as fractions of the largest one.
        var maxDensity: Float = 0
        forEachBlock(grid, log2Factor) { _, _, _, density in
            if density > maxDensity { maxDensity = density }
        }
        grid.forEachTile { _, _, _, _, value in
            if value > maxDensity { maxDensity = value }
        }
        let densityScale: Float = maxDensity > 0 ? 255 / maxDensity : 0

        var texels = [UInt8](repeating: 0, count: sizeX * sizeY * sizeZ * channels)
        texels.withUnsafeMutableBufferPointer { t in
            grid.forEachTile { x, y, z, log2Size, value in
                if value > 0 {
                    let tileTexels = (1 << log2Size) >> log2Factor
                    let tx = (x >> log2Factor) - lo[0]
                    let ty = (y >> log2Factor) - lo[1]
                    let tz = (z >> log2Factor) - lo[2]
                    let density = toByte(value * densityScale)
                    for k in tz..<(tz + tileTexels) {
                        for j in ty..<(ty + tileTexels) {
                            for i in tx..<(tx + tileTexels) {
                                t[((k * sizeY + j) * sizeX + i) * channels] = density
                            }
                        }
                    }
                }
            }
            forEachBlock(grid, log2Factor) { x, y, z, density in
                if density > 0 {
                    t[(((z - lo[2]) * sizeY + y - lo[1]) * sizeX + x - lo[0]) * channels] = toByte(density * densityScale)
                }
            }
        }

        let texelOrigin = (0..<3).map { lo[$0] << log2Factor }
        let textureToWorld = computeTextureToWorld(size, texelOrigin, factor, grid.transform)
        let centroid = computeLight(size, &texels, channels, maxDensity, grid.transform, factor, textureToWorld)

        // The temperature and color only matter where there's density, since only a volume
        // with density reflects light, or glows by its temperature. Flames glow anywhere.
        let firstTexel = [0, 0, 0]
        var flameLength = 0.0
        if glow != .none, let glowGrid {
            let cold = glowGrid.background
            let glowScale: Float = 255 / (hottest - cold)
            let glowLo = glow == .flame ? (0..<3).map { (flameMin[$0] >> log2Factor) - lo[$0] } : firstTexel
            let glowHi = glow == .flame ? (0..<3).map { (flameMax[$0] >> log2Factor) - lo[$0] + 1 } : size
            var glowSum = 0.0
            texels.withUnsafeMutableBufferPointer { t in
                sampleAtTexels(size, glowLo, glowHi, glow == .thermal, UnsafeBufferPointer(t), channels, textureToWorld, glowGrid) { i, _, value in
                    let glowByte = toByte((value.x - cold) * glowScale)
                    t[i * channels + 2] = glowByte
                    glowSum += Double(glowByte) / 255
                }
            }
            if glow == .flame {
                let texelSize = Double(factor) * cbrt(abs(VdbGrid.determinant3x3(grid.transform)))
                flameLength = cbrt(glowSum) * texelSize
            }
        }
        var color: [UInt8]?
        if let colorGrid {
            // Colors are premultiplied by the density, so that filtering the texture doesn't
            // blend in the colors of empty texels.
            var colors = [UInt8](repeating: 0, count: sizeX * sizeY * sizeZ * 3)
            colors.withUnsafeMutableBufferPointer { out in
                texels.withUnsafeBufferPointer { t in
                sampleAtTexels(size, firstTexel, size, true, t, channels, textureToWorld, colorGrid) { i, density, value in
                    for c in 0..<3 {
                        out[i * 3 + c] = toByte(VdbModel.linearToSrgb(Swift.min(Swift.max(value[c], 0), 1) * density) * 255)
                    }
                }
                }
            }
            color = colors
        }
        return VolumeTexture(sizeX: sizeX, sizeY: sizeY, sizeZ: sizeZ, origin: texelOrigin, factor: factor,
                             gridTransform: grid.transform, maxDensity: maxDensity, glow: glow, flameLength: flameLength,
                             texels: texels, color: color, centroid: centroid)
    }

    /// Calls the given function with the average density of each block of voxels in the leaves
    /// (whose size is the given resolution factor), and the block's texel coordinates.
    private static func forEachBlock(_ grid: VdbGrid, _ log2Factor: Int,
                                     _ action: (_ x: Int, _ y: Int, _ z: Int, _ density: Float) -> Void) {
        let leafLog2 = grid.leafLog2
        let factor = 1 << log2Factor
        let blocks = grid.leafDim >> log2Factor
        let scale = 1 / Float(factor * factor * factor)
        let components = grid.components
        for (key, values) in grid.leaves {
            let originX = VdbGrid.unpackKeyX(key) << (leafLog2 - log2Factor)
            let originY = VdbGrid.unpackKeyY(key) << (leafLog2 - log2Factor)
            let originZ = VdbGrid.unpackKeyZ(key) << (leafLog2 - log2Factor)
            values.withUnsafeBufferPointer { v in
                for bx in 0..<blocks {
                    for by in 0..<blocks {
                        for bz in 0..<blocks {
                            var sum: Float = 0
                            for x in (bx * factor)..<((bx + 1) * factor) {
                                for y in (by * factor)..<((by + 1) * factor) {
                                    for z in (bz * factor)..<((bz + 1) * factor) {
                                        sum += v[((x << (2 * leafLog2)) | (y << leafLog2) | z) * components]
                                    }
                                }
                            }
                            action(originX + bx, originY + by, originZ + bz, sum * scale)
                        }
                    }
                }
            }
        }
    }

    /// Computes how much of the light from straight above (along the world's y axis) reaches each
    /// texel, by attenuating it through the volume along the texture axis that's closest to vertical.
    /// Returns the density-weighted center of the volume (or the center of the texture, if it has
    /// no density), in world coordinates.
    private static func computeLight(_ size: [Int], _ texels: inout [UInt8], _ channels: Int, _ maxDensity: Float,
                                     _ gridTransform: [Double], _ factor: Int, _ textureToWorld: [Double]) -> [Double] {
        let up = (0..<3).max { abs(gridTransform[$0 * 3 + 1]) < abs(gridTransform[$1 * 3 + 1]) }!
        let upIsPositive = gridTransform[up * 3 + 1] >= 0
        let axis1 = (up + 1) % 3
        let axis2 = (up + 2) % 3
        let stride = [1, size[0], size[0] * size[1]]
        let stepLength = Double(factor) * (0..<3).reduce(0.0) { $0 + gridTransform[up * 3 + $1] * gridTransform[up * 3 + $1] }.squareRoot()

        // Fractions of light that pass through half of a texel, and through all of it, for each density.
        var halfTransmittance = [Float](repeating: 0, count: 256)
        var fullTransmittance = [Float](repeating: 0, count: 256)
        for d in 0..<256 {
            let opticalDepth = Double(d) / 255 * Double(maxDensity) * Double(extinctionScale) * stepLength
            halfTransmittance[d] = Float(exp(-opticalDepth / 2))
            fullTransmittance[d] = Float(exp(-opticalDepth))
        }

        var weight = 0.0
        var weightedSum = [0.0, 0.0, 0.0]
        let size1 = size[axis1], size2 = size[axis2], sizeUp = size[up]
        let stride1 = stride[axis1], stride2 = stride[axis2], strideUp = stride[up]
        var sum1 = 0.0, sum2 = 0.0, sumUp = 0.0
        texels.withUnsafeMutableBufferPointer { t in
            for i1 in 0..<size1 {
                for i2 in 0..<size2 {
                    var transmittance: Float = 1
                    for n in 0..<sizeUp {
                        let k = upIsPositive ? sizeUp - 1 - n : n
                        let i = i1 * stride1 + i2 * stride2 + k * strideUp
                        let density = Int(t[i * channels])
                        t[i * channels + 1] = toByte(transmittance * halfTransmittance[density] * 255)
                        transmittance *= fullTransmittance[density]
                        if density > 0 {
                            let d = Double(density)
                            weight += d
                            sum1 += d * (Double(i1) + 0.5) / Double(size1)
                            sum2 += d * (Double(i2) + 0.5) / Double(size2)
                            sumUp += d * (Double(k) + 0.5) / Double(sizeUp)
                        }
                    }
                }
            }
        }
        weightedSum[axis1] = sum1
        weightedSum[axis2] = sum2
        weightedSum[up] = sumUp
        if weight == 0 {
            return transform(textureToWorld, 0.5, 0.5, 0.5)
        }
        return transform(textureToWorld, weightedSum[0] / weight, weightedSum[1] / weight, weightedSum[2] / weight)
    }

    /// Samples the given grid at the center of each texel from `lo` (inclusive) to `hi`
    /// (exclusive), optionally only the texels that have any density, and calls the given
    /// function with the texel's index, its density (as a fraction), and the grid's value.
    private static func sampleAtTexels(_ size: [Int], _ lo: [Int], _ hi: [Int], _ requireDensity: Bool, _ t: UnsafeBufferPointer<UInt8>,
                                       _ channels: Int, _ textureToWorld: [Double], _ grid: VdbGrid,
                                       _ action: (_ index: Int, _ density: Float, _ value: SIMD3<Float>) -> Void) {
        let m = textureToWorld
        do {
            for z in lo[2]..<Swift.max(hi[2], lo[2]) {
                let w = (Double(z) + 0.5) / Double(size[2])
                for y in lo[1]..<Swift.max(hi[1], lo[1]) {
                    let v = (Double(y) + 0.5) / Double(size[1])
                    for x in lo[0]..<Swift.max(hi[0], lo[0]) {
                        let i = (z * size[1] + y) * size[0] + x
                        let density = Float(t[i * channels]) / 255
                        if requireDensity && density == 0 {
                            continue
                        }
                        let u = (Double(x) + 0.5) / Double(size[0])
                        let value = grid.sample3(u * m[0] + v * m[3] + w * m[6] + m[9], u * m[1] + v * m[4] + w * m[7] + m[10],
                                                 u * m[2] + v * m[5] + w * m[8] + m[11])
                        action(i, density, value)
                    }
                }
            }
        }
    }

    /// Expands the given extent (in index coordinates) to include the voxels of the grid whose
    /// values (in their first component) exceed the given threshold.
    private static func includeValuesAbove(_ grid: VdbGrid, _ threshold: Float, _ min: inout [Int], _ max: inout [Int]) {
        let leafLog2 = grid.leafLog2
        let leafMask = grid.leafDim - 1
        let count = 1 << (3 * leafLog2)
        let components = grid.components
        var lo = (Int.max, Int.max, Int.max)
        var hi = (Int.min, Int.min, Int.min)
        for (key, values) in grid.leaves {
            let originX = VdbGrid.unpackKeyX(key) << leafLog2
            let originY = VdbGrid.unpackKeyY(key) << leafLog2
            let originZ = VdbGrid.unpackKeyZ(key) << leafLog2
            values.withUnsafeBufferPointer { v in
                for i in 0..<count where v[i * components] > threshold {
                    let x = originX + (i >> (2 * leafLog2))
                    let y = originY + ((i >> leafLog2) & leafMask)
                    let z = originZ + (i & leafMask)
                    if x < lo.0 { lo.0 = x }
                    if y < lo.1 { lo.1 = y }
                    if z < lo.2 { lo.2 = z }
                    if x > hi.0 { hi.0 = x }
                    if y > hi.1 { hi.1 = y }
                    if z > hi.2 { hi.2 = z }
                }
            }
        }
        if lo.0 <= hi.0 {
            include(&min, &max, lo.0, lo.1, lo.2)
            include(&min, &max, hi.0, hi.1, hi.2)
        }
        grid.forEachTile { x, y, z, log2Size, value in
            if value > threshold {
                let last = (1 << log2Size) - 1
                include(&min, &max, x, y, z)
                include(&min, &max, x + last, y + last, z + last)
            }
        }
    }

    /// Expands the given extent (in the index coordinates of `grid`) to include the voxels of
    /// another grid whose values exceed its background, which may have a different transform.
    private static func includeOtherGrid(_ other: VdbGrid, _ grid: VdbGrid, _ min: inout [Int], _ max: inout [Int]) {
        var otherMin = [Int](repeating: Int.max, count: 3)
        var otherMax = [Int](repeating: Int.min, count: 3)
        includeValuesAbove(other, other.background, &otherMin, &otherMax)
        if otherMin[0] > otherMax[0] {
            return
        }
        for n in 0..<8 {
            let world = other.indexToWorld(
                Double(n & 1 == 0 ? otherMin[0] : otherMax[0]),
                Double(n & 2 == 0 ? otherMin[1] : otherMax[1]),
                Double(n & 4 == 0 ? otherMin[2] : otherMax[2]))
            let index = grid.worldToIndex(world[0], world[1], world[2])
            // Round outward, but not past positions that are whole numbers, apart from rounding errors.
            include(&min, &max, Int((index[0] + rounding).rounded(.down)), Int((index[1] + rounding).rounded(.down)),
                    Int((index[2] + rounding).rounded(.down)))
            include(&min, &max, Int((index[0] - rounding).rounded(.up)), Int((index[1] - rounding).rounded(.up)),
                    Int((index[2] - rounding).rounded(.up)))
        }
    }

    /// The highest value of a scalar grid, including its tiles.
    private static func maxValue(_ grid: VdbGrid) -> Float {
        var max = grid.maxValue
        grid.forEachTile { _, _, _, _, value in
            if value > max { max = value }
        }
        return max
    }

    /// Linear sRGB color of a blackbody at the given temperature (in Kelvin), scaled so that its
    /// largest component is 1. This integrates Planck's law over the visible spectrum with the
    /// CIE 1931 color matching functions, using the analytic fit of Wyman, Sloan, and Shirley (2013).
    static func blackbodyColor(_ kelvin: Double) -> [Float] {
        var x = 0.0
        var y = 0.0
        var z = 0.0
        for nm in stride(from: 380, through: 780, by: 5) {
            let lambda = Double(nm) * 1e-9
            // Planck's law, without its constant factors, which don't affect the color.
            let radiance = 1 / (pow(lambda, 5) * (exp(planckC2 / (lambda * kelvin)) - 1))
            x += radiance * (1.056 * lobe(nm, 599.8, 37.9, 31.0) + 0.362 * lobe(nm, 442.0, 16.0, 26.7) -
                             0.065 * lobe(nm, 501.1, 20.4, 26.2))
            y += radiance * (0.821 * lobe(nm, 568.8, 46.9, 40.5) + 0.286 * lobe(nm, 530.9, 16.3, 31.1))
            z += radiance * (1.217 * lobe(nm, 437.0, 11.8, 36.0) + 0.681 * lobe(nm, 459.0, 26.0, 13.8))
        }
        let rgb = [3.2406 * x - 1.5372 * y - 0.4986 * z, -0.9689 * x + 1.8758 * y + 0.0415 * z,
                   0.0557 * x - 0.2040 * y + 1.0570 * z]
        let max = rgb.max()!
        return rgb.map { Float(Swift.max($0, 0) / max) }
    }

    /// A Gaussian lobe with different widths below and above its mean.
    private static func lobe(_ nm: Int, _ mean: Double, _ widthBelow: Double, _ widthAbove: Double) -> Double {
        let t = (Double(nm) - mean) / (Double(nm) < mean ? widthBelow : widthAbove)
        return exp(-0.5 * t * t)
    }

    private static func computeTextureToWorld(_ size: [Int], _ origin: [Int], _ factor: Int, _ gridTransform: [Double]) -> [Double] {
        var matrix = [Double](repeating: 0, count: 12)
        for j in 0..<3 {
            var translation = gridTransform[9 + j]
            for a in 0..<3 {
                matrix[a * 3 + j] = gridTransform[a * 3 + j] * Double(size[a] * factor)
                // Voxel values lie at integer coordinates, so the voxels' extent begins half a voxel before the origin.
                translation += (Double(origin[a]) - 0.5) * gridTransform[a * 3 + j]
            }
            matrix[9 + j] = translation
        }
        return matrix
    }

    /// Applies a 4x3 affine matrix to a point.
    static func transform(_ m: [Double], _ x: Double, _ y: Double, _ z: Double) -> [Double] {
        (0..<3).map { x * m[$0] + y * m[3 + $0] + z * m[6 + $0] + m[9 + $0] }
    }

    private static func include(_ min: inout [Int], _ max: inout [Int], _ x: Int, _ y: Int, _ z: Int) {
        if x < min[0] { min[0] = x }
        if y < min[1] { min[1] = y }
        if z < min[2] { min[2] = z }
        if x > max[0] { max[0] = x }
        if y > max[1] { max[1] = y }
        if z > max[2] { max[2] = z }
    }

    @inline(__always)
    static func toByte(_ value: Float) -> UInt8 {
        let v = value + 0.5
        if !(v >= 0) { return 0 }
        if v >= 255 { return 255 }
        return UInt8(Int(v))
    }
}
