//
//  MeshModel.swift
//  ModelViewer
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

/// A model made of triangles (or points), with optional colors, texture coordinates, and materials.
class MeshModel: Model, @unchecked Sendable {
    /// Vertex positions (3 floats per vertex).
    var vertices: [Float] = []

    /// Vertex normals (3 floats per vertex).
    var normals: [Float] = []

    /// Optional vertex colors (RGBA, 4 floats per vertex).
    var colors: [Float]?

    /// Optional texture coordinates (2 floats per vertex), with the origin at the bottom left of the texture.
    var texCoords: [Float]?

    /// Optional triangle indices (3 per triangle). Without them, every three consecutive vertices form a triangle.
    var indices: [UInt32]?

    /// Parts of the mesh that have their own materials. If empty, the whole mesh is drawn with one default material.
    /// The range of each part is in indices, if there are any, or else in vertices.
    var parts: [MeshPart] = []

    /// Whether the vertices are drawn as points, with their colors, rather than as triangles.
    var isPointCloud = false

    var vertexCount: Int { vertices.count / 3 }
    var indexCount: Int { indices?.count ?? 0 }

    /// Number of elements (indices, or else vertices) that are drawn.
    var elementCount: Int { indices?.count ?? vertexCount }

    /// Whether the model has any surface properties besides its shape.
    var hasMaterials: Bool { colors != nil || !parts.isEmpty }

    /// Sets the center of mass to the average of the vertices, and the bounds to their extent.
    func computeBoundsFromVertices() {
        var sumX = 0.0, sumY = 0.0, sumZ = 0.0
        let count = vertexCount
        vertices.withUnsafeBufferPointer { v in
            for i in 0..<count {
                let x = v[i * 3], y = v[i * 3 + 1], z = v[i * 3 + 2]
                adjustMaxMin(x, y, z)
                sumX += Double(x)
                sumY += Double(y)
                sumZ += Double(z)
            }
        }
        if count > 0 {
            centerMassX = Float(sumX / Double(count))
            centerMassY = Float(sumY / Double(count))
            centerMassZ = Float(sumZ / Double(count))
        }
    }
}

/// A range of a mesh that's drawn with one material.
struct MeshPart: Sendable {
    let material: Material
    /// First index (or vertex, if the mesh has no indices) of the range.
    let first: Int
    /// Number of indices (or vertices) in the range.
    let count: Int
}
