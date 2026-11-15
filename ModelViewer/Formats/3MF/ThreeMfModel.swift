//
//  ThreeMfModel.swift
//  ModelViewer
//
//  Displays a 3MF model: the objects in its build, with their colors and textures. Like STL files,
//  3MF files are mostly made for 3D printing, so the models are flat shaded, with the Z axis up.
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

final class ThreeMfModel: MeshModel, @unchecked Sendable {
    // The Z axis is up, as in STL files.
    override var orientation: ModelOrientation { .zUp }

    init(data: Data) throws {
        super.init()
        let mesh = try ThreeMfReader(data: data).read()
        if mesh.triangleCount == 0 {
            throw ModelError("No triangles found in model.")
        }
        setMesh(mesh)
    }

    private func setMesh(_ mesh: ThreeMfReader.Mesh) {
        vertices = mesh.positions
        normals = Self.faceNormals(mesh.positions, mesh.triangleCount)
        computeBoundsFromVertices()
        colors = mesh.colors
        if let texCoords = mesh.texCoords {
            self.texCoords = texCoords
            parts = mesh.parts.map { part in
                let material = (part.texture != nil || mesh.colors != nil) ? Material.forVertexColors() : Material()
                material.diffuseTexture = part.texture
                material.diffuseTextureName = part.textureName
                return MeshPart(material: material, first: part.firstTriangle * 3, count: part.triangleCount * 3)
            }
        }
    }

    /// The normal of each triangle, at each of its corners.
    private static func faceNormals(_ positions: [Float], _ triangleCount: Int) -> [Float] {
        var normals = [Float](repeating: 0, count: triangleCount * 9)
        positions.withUnsafeBufferPointer { p in
            normals.withUnsafeMutableBufferPointer { n in
                for t in 0..<triangleCount {
                    let i = t * 9
                    let e1x = p[i + 3] - p[i], e1y = p[i + 4] - p[i + 1], e1z = p[i + 5] - p[i + 2]
                    let e2x = p[i + 6] - p[i], e2y = p[i + 7] - p[i + 1], e2z = p[i + 8] - p[i + 2]
                    var nx = e1y * e2z - e1z * e2y
                    var ny = e1z * e2x - e1x * e2z
                    var nz = e1x * e2y - e1y * e2x
                    let length = (nx * nx + ny * ny + nz * nz).squareRoot()
                    if length > 0 {
                        nx /= length
                        ny /= length
                        nz /= length
                    }
                    for c in 0..<3 {
                        n[i + c * 3] = nx
                        n[i + c * 3 + 1] = ny
                        n[i + c * 3 + 2] = nz
                    }
                }
            }
        }
        return normals
    }
}
