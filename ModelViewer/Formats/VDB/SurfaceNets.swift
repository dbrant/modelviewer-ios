//
//  SurfaceNets.swift
//  ModelViewer
//
//  Extracts the surface of a VDB grid, where its value crosses an iso value, as a mesh of quads
//  (split into triangles), using the Surface Nets algorithm: a vertex is placed in each cell (the
//  cube between eight neighboring voxels) that the surface passes through, and the vertices of the
//  four cells around each cell edge that the surface crosses are joined into a quad.
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

final class SurfaceNets {
    struct Mesh {
        /// Vertex positions (3 floats per vertex), in world coordinates.
        let vertices: [Float]
        /// Vertex normals (3 floats per vertex).
        let normals: [Float]
        /// Triangle indices (3 per triangle).
        let indices: [UInt32]

        var vertexCount: Int { vertices.count / 3 }
        var indexCount: Int { indices.count }
    }

    // Pairs of cell corners that make up the 12 edges of a cell. Corner n is at offset
    // (n & 1, (n >> 1) & 1, (n >> 2) & 1).
    private static let edges: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7,
        0, 2, 1, 3, 4, 6, 5, 7,
        0, 4, 1, 5, 2, 6, 3, 7]

    private let grid: VdbGrid
    private let isoValue: Float
    private let insideIsAbove: Bool

    /// - Parameters:
    ///   - isoValue: The value at which the surface lies.
    ///   - insideIsAbove: Whether the inside of the surface has values above the iso value (as in fog
    ///     volumes), rather than below it (as in level sets).
    init(grid: VdbGrid, isoValue: Float, insideIsAbove: Bool) {
        self.grid = grid
        self.isoValue = isoValue
        self.insideIsAbove = insideIsAbove
    }

    /// Extracts the surface, in world coordinates.
    func extract() -> Mesh {
        let dim = grid.leafDim
        let paddedDim = dim + 1
        let cellCount = dim * dim * dim

        // The cells whose lowest corner lies in a leaf, or just below a leaf (along any axis),
        // are the ones that can contain the surface.
        var blockKeys = Set<Int64>(minimumCapacity: grid.leaves.count * 4)
        for key in grid.leaves.keys {
            let x = VdbGrid.unpackKeyX(key)
            let y = VdbGrid.unpackKeyY(key)
            let z = VdbGrid.unpackKeyZ(key)
            for n in 0..<8 {
                blockKeys.insert(VdbGrid.packKey(x - (n & 1), y - ((n >> 1) & 1), z - ((n >> 2) & 1)))
            }
        }

        var positions: [Float] = []
        var normals: [Float] = []
        positions.reserveCapacity(0x10000)
        normals.reserveCapacity(0x10000)
        var cellVertices: [Int64: [Int32]] = [:]
        var cellMasks: [Int64: [UInt8]] = [:]
        var padded = [Float](repeating: 0, count: paddedDim * paddedDim * paddedDim)
        var masks = [UInt8](repeating: 0, count: cellCount)
        var vertexCount: Int32 = 0
        let m = grid.transform
        let edges = Self.edges

        // Pass 1: create a vertex in each cell that the surface passes through.
        for key in blockKeys {
            let bx = VdbGrid.unpackKeyX(key)
            let by = VdbGrid.unpackKeyY(key)
            let bz = VdbGrid.unpackKeyZ(key)
            fillPaddedBlock(bx, by, bz, &padded)

            var vertices: [Int32]?
            padded.withUnsafeBufferPointer { p in
                var corners = (Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0))
                for x in 0..<dim {
                    for y in 0..<dim {
                        for z in 0..<dim {
                            var mask = 0
                            withUnsafeMutableBytes(of: &corners) { raw in
                                let c = raw.bindMemory(to: Float.self)
                                for n in 0..<8 {
                                    let v = p[((x + (n & 1)) * paddedDim + y + ((n >> 1) & 1)) * paddedDim + z + ((n >> 2) & 1)]
                                    c[n] = v
                                    if v < 0 { mask |= 1 << n }
                                }
                            }
                            let cell = (x * dim + y) * dim + z
                            masks[cell] = UInt8(mask)
                            if mask == 0 || mask == 0xff {
                                continue
                            }
                            if vertices == nil {
                                vertices = [Int32](repeating: -1, count: cellCount)
                            }
                            vertices![cell] = vertexCount
                            vertexCount += 1

                            withUnsafeBytes(of: corners) { raw in
                                let c = raw.bindMemory(to: Float.self)
                                // Place the vertex at the average of the points where the surface crosses the cell edges.
                                var point = SIMD3<Float>(0, 0, 0)
                                var crossings: Float = 0
                                for e in 0..<12 {
                                    let c0 = edges[e * 2]
                                    let c1 = edges[e * 2 + 1]
                                    let f0 = c[c0]
                                    let f1 = c[c1]
                                    if (f0 < 0) == (f1 < 0) {
                                        continue
                                    }
                                    let t = f0 / (f0 - f1)
                                    for axis in 0..<3 {
                                        let p0 = Float((c0 >> axis) & 1)
                                        let p1 = Float((c1 >> axis) & 1)
                                        point[axis] += p0 + t * (p1 - p0)
                                    }
                                    crossings += 1
                                }
                                // Voxel (index space) coordinates, then transformed to world space.
                                let sx = Double(Float(bx * dim + x) + point.x / crossings)
                                let sy = Double(Float(by * dim + y) + point.y / crossings)
                                let sz = Double(Float(bz * dim + z) + point.z / crossings)
                                positions.append(Float(sx * m[0] + sy * m[3] + sz * m[6] + m[9]))
                                positions.append(Float(sx * m[1] + sy * m[4] + sz * m[7] + m[10]))
                                positions.append(Float(sx * m[2] + sy * m[5] + sz * m[8] + m[11]))

                                // The normal is the gradient of the field, which points outward since the field is
                                // negative inside the surface.
                                normals.append((c[1] - c[0]) + (c[3] - c[2]) + (c[5] - c[4]) + (c[7] - c[6]))
                                normals.append((c[2] - c[0]) + (c[3] - c[1]) + (c[6] - c[4]) + (c[7] - c[5]))
                                normals.append((c[4] - c[0]) + (c[5] - c[1]) + (c[6] - c[2]) + (c[7] - c[3]))
                            }
                        }
                    }
                }
            }
            if let vertices {
                cellVertices[key] = vertices
                cellMasks[key] = masks
            }
        }

        // Pass 2: connect the vertices of the four cells around each edge that the surface crosses.
        var indices: [UInt32] = []
        indices.reserveCapacity(Int(vertexCount) * 6)
        var neighbors = [[Int32]?](repeating: nil, count: 8)
        var quad = [UInt32](repeating: 0, count: 4)
        for (key, vertices) in cellVertices {
            let bx = VdbGrid.unpackKeyX(key)
            let by = VdbGrid.unpackKeyY(key)
            let bz = VdbGrid.unpackKeyZ(key)
            let masks = cellMasks[key]!
            // Cells along an edge may be in the neighboring blocks below this one.
            for n in 0..<8 {
                neighbors[n] = n == 0 ? vertices :
                    cellVertices[VdbGrid.packKey(bx - (n & 1), by - ((n >> 1) & 1), bz - ((n >> 2) & 1))]
            }
            for x in 0..<dim {
                for y in 0..<dim {
                    for z in 0..<dim {
                        let cell = (x * dim + y) * dim + z
                        if vertices[cell] < 0 {
                            continue
                        }
                        let mask = Int(masks[cell])
                        let inside0 = mask & 1
                        for axis in 0..<3 {
                            let inside1 = (mask >> (1 << axis)) & 1
                            if inside0 == inside1 {
                                continue
                            }
                            // The other two axes, in cyclic order, so that the quad winds counterclockwise
                            // when viewed from the direction that the edge points.
                            let axisU = (axis + 1) % 3
                            let axisV = (axis + 2) % 3
                            var valid = true
                            for q in 0..<4 {
                                // Quad corners: (-1,-1), (0,-1), (0,0), (-1,0) in (u,v)
                                let du = (q == 0 || q == 3) ? -1 : 0
                                let dv = q < 2 ? -1 : 0
                                let cx = x + (axisU == 0 ? du : 0) + (axisV == 0 ? dv : 0)
                                let cy = y + (axisU == 1 ? du : 0) + (axisV == 1 ? dv : 0)
                                let cz = z + (axisU == 2 ? du : 0) + (axisV == 2 ? dv : 0)
                                let neighbor = (cx < 0 ? 1 : 0) | (cy < 0 ? 2 : 0) | (cz < 0 ? 4 : 0)
                                var v: Int32 = -1
                                if let array = neighbors[neighbor] {
                                    v = array[(((cx + dim) % dim) * dim + (cy + dim) % dim) * dim + (cz + dim) % dim]
                                }
                                if v < 0 {
                                    valid = false
                                    break
                                }
                                quad[q] = UInt32(v)
                            }
                            if !valid {
                                continue
                            }
                            // If the inside is at the lower end of the edge, the surface faces toward
                            // the positive direction of the edge.
                            if inside0 == 1 {
                                indices.append(quad[0]); indices.append(quad[1]); indices.append(quad[2])
                                indices.append(quad[0]); indices.append(quad[2]); indices.append(quad[3])
                            } else {
                                indices.append(quad[0]); indices.append(quad[2]); indices.append(quad[1])
                                indices.append(quad[0]); indices.append(quad[3]); indices.append(quad[2])
                            }
                        }
                    }
                }
            }
        }

        transformNormals(&normals)
        if VdbGrid.determinant3x3(grid.transform) < 0 {
            // A mirroring transform reverses the winding of the triangles.
            var i = 0
            while i < indices.count {
                indices.swapAt(i + 1, i + 2)
                i += 3
            }
        }
        return Mesh(vertices: positions, normals: normals, indices: indices)
    }

    /// Fills an array of (dim+1)^3 values of the implicit function (negative inside the surface),
    /// covering the given leaf-sized block and one voxel past its upper boundary along each axis.
    private func fillPaddedBlock(_ bx: Int, _ by: Int, _ bz: Int, _ padded: inout [Float]) {
        let dim = grid.leafDim
        let paddedDim = dim + 1
        let iso = isoValue
        let insideIsAbove = self.insideIsAbove
        padded.withUnsafeMutableBufferPointer { out in
            for n in 0..<8 {
                let nx = n & 1
                let ny = (n >> 1) & 1
                let nz = (n >> 2) & 1
                let block = grid.leaves[VdbGrid.packKey(bx + nx, by + ny, bz + nz)]
                let tileValue = block == nil ? grid.tileValue((bx + nx) * dim, (by + ny) * dim, (bz + nz) * dim) : 0
                // The region of the padded array that comes from this neighbor
                let x0 = nx * dim
                let x1 = nx == 0 ? dim : paddedDim
                let y0 = ny * dim
                let y1 = ny == 0 ? dim : paddedDim
                let z0 = nz * dim
                let z1 = nz == 0 ? dim : paddedDim
                for x in x0..<x1 {
                    for y in y0..<y1 {
                        for z in z0..<z1 {
                            let value = block?[((x - x0) * dim + (y - y0)) * dim + (z - z0)] ?? tileValue
                            out[(x * paddedDim + y) * paddedDim + z] = insideIsAbove ? iso - value : value - iso
                        }
                    }
                }
            }
        }
    }

    /// Transforms normals from index space to world space, which requires the inverse transpose of
    /// the transform's linear part. Since the matrix is applied to row vectors, that works out to
    /// multiplying the normal (as a column vector) by the plain inverse.
    private func transformNormals(_ normals: inout [Float]) {
        let inv = VdbGrid.invert3x3(grid.transform)
        var i = 0
        while i < normals.count {
            let x = Double(normals[i])
            let y = Double(normals[i + 1])
            let z = Double(normals[i + 2])
            let nx = Float(inv[0] * x + inv[1] * y + inv[2] * z)
            let ny = Float(inv[3] * x + inv[4] * y + inv[5] * z)
            let nz = Float(inv[6] * x + inv[7] * y + inv[8] * z)
            let length = (nx * nx + ny * ny + nz * nz).squareRoot()
            if length > 0 {
                normals[i] = nx / length
                normals[i + 1] = ny / length
                normals[i + 2] = nz / length
            }
            i += 3
        }
    }
}
