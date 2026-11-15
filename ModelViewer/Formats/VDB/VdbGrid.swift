//
//  VdbGrid.swift
//  ModelViewer
//
//  A sparse grid of values read from an OpenVDB file: the voxels of its leaf nodes, and the tile
//  values of its internal and root nodes (regions that have a single value).
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

final class VdbGrid: @unchecked Sendable {
    static let gridClassLevelSet = "level set"
    static let gridClassFogVolume = "fog volume"

    private static let keyBits: Int64 = 21
    private static let keyMask: Int64 = (1 << keyBits) - 1

    struct InternalLevel {
        let log2: Int
        let totalLog2: Int
        let nodes: [Int64: [Float]]
    }

    let name: String
    let gridClass: String
    /// Number of floats in each value: 1 for scalar grids, or 3 for vector grids.
    let components: Int
    let backgroundValue: [Float]
    /// Index-to-world transform as a 4x3 affine matrix, applied to row vectors: [x y z 1] * M.
    let transform: [Double]
    /// Log2 of the leaf node dimension (3 for standard 8x8x8 leaves).
    let leafLog2: Int
    /// Tile values of internal nodes, ordered from the level just above the leaves to the top.
    let internalLevels: [InternalLevel]
    /// Tile values of the root node, keyed by tile origin shifted right by `rootChildLog2`.
    let rootTiles: [Int64: [Float]]
    let rootChildLog2: Int
    /// Voxel values of each leaf node (with `components` floats per voxel), keyed by leaf origin shifted right by `leafLog2`.
    let leaves: [Int64: [Float]]
    let minValue: Float
    let maxValue: Float

    private let inverseTransform: [Double]
    private var cachedLeafKey = Int64.min
    private var cachedLeaf: [Float]?

    init(name: String, gridClass: String, components: Int, backgroundValue: [Float], transform: [Double], leafLog2: Int,
         internalLevels: [InternalLevel], rootTiles: [Int64: [Float]], rootChildLog2: Int, leaves: [Int64: [Float]],
         minValue: Float, maxValue: Float) {
        self.name = name
        self.gridClass = gridClass
        self.components = components
        self.backgroundValue = backgroundValue
        self.transform = transform
        self.leafLog2 = leafLog2
        self.internalLevels = internalLevels
        self.rootTiles = rootTiles
        self.rootChildLog2 = rootChildLog2
        self.leaves = leaves
        self.minValue = minValue
        self.maxValue = maxValue
        self.inverseTransform = Self.invert3x3(transform)
    }

    var leafDim: Int { 1 << leafLog2 }

    /// The background value of a scalar grid.
    var background: Float { backgroundValue[0] }

    var isLevelSet: Bool {
        switch gridClass {
        case Self.gridClassLevelSet: true
        case Self.gridClassFogVolume: false
        default: minValue < 0 && maxValue > 0
        }
    }

    /// Returns the (first component of the) value at the given voxel coordinates, for a location
    /// that is not inside any leaf node.
    func tileValue(_ x: Int, _ y: Int, _ z: Int) -> Float {
        tile3(x, y, z).x
    }

    /// Gets the value at the given voxel coordinates, for a location that is not inside any leaf node.
    func tileValue(_ x: Int, _ y: Int, _ z: Int, _ value: inout [Float]) {
        let v = tile3(x, y, z)
        for c in 0..<components {
            value[c] = v[c]
        }
    }

    /// The value (up to three components) of the tile that contains the given voxel coordinates.
    private func tile3(_ x: Int, _ y: Int, _ z: Int) -> SIMD3<Float> {
        for level in internalLevels {
            guard let node = level.nodes[Self.packKey(x >> level.totalLog2, y >> level.totalLog2, z >> level.totalLog2)] else {
                continue
            }
            let childLog2 = level.totalLog2 - level.log2
            let mask = (1 << level.log2) - 1
            let index = (((x >> childLog2) & mask) << (2 * level.log2)) |
                (((y >> childLog2) & mask) << level.log2) | ((z >> childLog2) & mask)
            return value3(node, index * components)
        }
        let tile = rootTiles[Self.packKey(x >> rootChildLog2, y >> rootChildLog2, z >> rootChildLog2)] ?? backgroundValue
        return value3(tile, 0)
    }

    @inline(__always)
    private func value3(_ array: [Float], _ i: Int) -> SIMD3<Float> {
        components == 1 ? SIMD3(array[i], 0, 0) : SIMD3(array[i], array[i + 1], array[i + 2])
    }

    /// Calls the given function for each tile of the internal nodes (a region with a single value,
    /// where there's no child node) whose value (in its first component) differs from the background,
    /// with the tile's origin, log2 size, and value. Tiles of the root node, which are enormous, aren't included.
    func forEachTile(_ action: (_ x: Int, _ y: Int, _ z: Int, _ log2Size: Int, _ value: Float) -> Void) {
        let background = self.background
        for (levelIndex, level) in internalLevels.enumerated() {
            let childLog2 = level.totalLog2 - level.log2
            let children = levelIndex == 0 ? leaves : internalLevels[levelIndex - 1].nodes
            let mask = (1 << level.log2) - 1
            let count = 1 << (3 * level.log2)
            for (key, values) in level.nodes {
                let originX = Self.unpackKeyX(key) << level.totalLog2
                let originY = Self.unpackKeyY(key) << level.totalLog2
                let originZ = Self.unpackKeyZ(key) << level.totalLog2
                for i in 0..<count {
                    let value = values[i * components]
                    if value == background {
                        continue
                    }
                    let x = originX + (((i >> (2 * level.log2)) & mask) << childLog2)
                    let y = originY + (((i >> level.log2) & mask) << childLog2)
                    let z = originZ + ((i & mask) << childLog2)
                    // The values of child nodes' positions aren't meaningful.
                    if children[Self.packKey(x >> childLog2, y >> childLog2, z >> childLog2)] == nil {
                        action(x, y, z, childLog2, value)
                    }
                }
            }
        }
    }

    /// The value (up to three components) at the given voxel coordinates.
    @inline(__always)
    private func voxel3(_ x: Int, _ y: Int, _ z: Int) -> SIMD3<Float> {
        let key = Self.packKey(x >> leafLog2, y >> leafLog2, z >> leafLog2)
        // Consecutive lookups are usually in the same leaf.
        if key != cachedLeafKey {
            cachedLeafKey = key
            cachedLeaf = leaves[key]
        }
        guard let leaf = cachedLeaf else {
            return tile3(x, y, z)
        }
        let mask = leafDim - 1
        let index = (((x & mask) << (2 * leafLog2)) | ((y & mask) << leafLog2) | (z & mask)) * components
        return value3(leaf, index)
    }

    /// Gets the value at the given voxel coordinates.
    func voxelValue(_ x: Int, _ y: Int, _ z: Int, _ value: inout [Float]) {
        let v = voxel3(x, y, z)
        for c in 0..<components {
            value[c] = v[c]
        }
    }

    /// Transforms a position in index coordinates to world coordinates.
    func indexToWorld(_ x: Double, _ y: Double, _ z: Double) -> [Double] {
        let m = transform
        return [x * m[0] + y * m[3] + z * m[6] + m[9], x * m[1] + y * m[4] + z * m[7] + m[10],
                x * m[2] + y * m[5] + z * m[8] + m[11]]
    }

    /// Transforms a position in world coordinates to (fractional) index coordinates.
    func worldToIndex(_ x: Double, _ y: Double, _ z: Double) -> [Double] {
        let m = inverseTransform
        let dx = x - transform[9]
        let dy = y - transform[10]
        let dz = z - transform[11]
        return [dx * m[0] + dy * m[3] + dz * m[6], dx * m[1] + dy * m[4] + dz * m[7],
                dx * m[2] + dy * m[5] + dz * m[8]]
    }

    /// Gets the value at the given world-space position, by trilinear interpolation of the surrounding voxels.
    func sample(_ x: Double, _ y: Double, _ z: Double, _ value: inout [Float]) {
        let v = sample3(x, y, z)
        for c in 0..<components {
            value[c] = v[c]
        }
    }

    /// The value (up to three components) at the given world-space position, by trilinear interpolation.
    func sample3(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Float> {
        // Transform to index space: subtract the translation, and multiply by the inverse of the linear part.
        let m = inverseTransform
        let dx = x - transform[9]
        let dy = y - transform[10]
        let dz = z - transform[11]
        let ix = dx * m[0] + dy * m[3] + dz * m[6]
        let iy = dx * m[1] + dy * m[4] + dz * m[7]
        let iz = dx * m[2] + dy * m[5] + dz * m[8]
        let x0 = Int(ix.rounded(.down))
        let y0 = Int(iy.rounded(.down))
        let z0 = Int(iz.rounded(.down))
        let fx = Float(ix - Double(x0))
        let fy = Float(iy - Double(y0))
        let fz = Float(iz - Double(z0))
        var result = SIMD3<Float>(0, 0, 0)
        for n in 0..<8 {
            let wx = n & 1 != 0 ? fx : 1 - fx
            let wy = n & 2 != 0 ? fy : 1 - fy
            let wz = n & 4 != 0 ? fz : 1 - fz
            let weight = wx * wy * wz
            if weight == 0 {
                continue
            }
            result += weight * voxel3(x0 + (n & 1), y0 + ((n >> 1) & 1), z0 + ((n >> 2) & 1))
        }
        return result
    }

    // MARK: - Keys and matrices

    @inline(__always)
    static func packKey(_ x: Int, _ y: Int, _ z: Int) -> Int64 {
        ((Int64(truncatingIfNeeded: x) & keyMask) << (2 * keyBits)) |
            ((Int64(truncatingIfNeeded: y) & keyMask) << keyBits) | (Int64(truncatingIfNeeded: z) & keyMask)
    }

    static func unpackKeyX(_ key: Int64) -> Int { signExtend(key >> (2 * keyBits)) }
    static func unpackKeyY(_ key: Int64) -> Int { signExtend(key >> keyBits) }
    static func unpackKeyZ(_ key: Int64) -> Int { signExtend(key) }

    @inline(__always)
    private static func signExtend(_ value: Int64) -> Int {
        Int(((value & keyMask) << (64 - keyBits)) >> (64 - keyBits))
    }

    /// Determinant of the 3x3 linear part of a transform (row-major).
    static func determinant3x3(_ m: [Double]) -> Double {
        m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6])
    }

    /// Inverse of the 3x3 linear part of a transform (row-major), or the identity if it's not invertible.
    static func invert3x3(_ m: [Double]) -> [Double] {
        let det = determinant3x3(m)
        if det == 0 {
            return [1, 0, 0, 0, 1, 0, 0, 0, 1]
        }
        return [
            (m[4] * m[8] - m[5] * m[7]) / det, (m[2] * m[7] - m[1] * m[8]) / det, (m[1] * m[5] - m[2] * m[4]) / det,
            (m[5] * m[6] - m[3] * m[8]) / det, (m[0] * m[8] - m[2] * m[6]) / det, (m[2] * m[3] - m[0] * m[5]) / det,
            (m[3] * m[7] - m[4] * m[6]) / det, (m[1] * m[6] - m[0] * m[7]) / det, (m[0] * m[4] - m[1] * m[3]) / det]
    }
}
