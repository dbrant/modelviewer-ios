//
//  VdbModel.swift
//  ModelViewer
//
//  An OpenVDB volume, shown as a surface: the zero crossing of a level set, or the boundary of
//  a fog volume (where its density reaches a fraction of its maximum).
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

final class VdbModel: MeshModel, @unchecked Sendable {
    /// The surface of a volume, with the colors of its vertices (if the volume has colors), which
    /// is extracted before the model is created, so that the grids can be released before then.
    struct Surface {
        let mesh: SurfaceNets.Mesh
        let colors: [Float]?
        let gridName: String
        let colorGridName: String?
        let isLevelSet: Bool
    }

    /// Fraction of the maximum density at which to draw the surface of a fog volume.
    static let fogIsoFraction: Float = 0.1

    let gridName: String
    let colorGridName: String?
    private let isLevelSet: Bool

    override var orientation: ModelOrientation { .native }

    override var subtitle: String? {
        var parts = [isLevelSet ? "Level set: \(gridName)" : "Surface of \(gridName)"]
        if let colorGridName {
            parts.append("color: \(colorGridName)")
        }
        return parts.joined(separator: " · ")
    }

    convenience init(data: Data) throws {
        try self.init(surface: Self.extractSurface(VdbReader(data: data).read()))
    }

    init(surface: Surface) throws {
        gridName = surface.gridName
        colorGridName = surface.colorGridName
        isLevelSet = surface.isLevelSet
        super.init()
        let mesh = surface.mesh
        if mesh.indexCount == 0 {
            throw ModelError("No surface found in volume.")
        }
        vertices = mesh.vertices
        normals = mesh.normals
        indices = mesh.indices
        colors = surface.colors
        computeBoundsFromVertices()
    }

    /// Extracts the surface of the volume (and the colors of its vertices, if there's a color grid).
    static func extractSurface(_ grids: VdbReader.Grids) -> Surface {
        let grid = grids.surface
        let surfaceNets = grid.isLevelSet
            ? SurfaceNets(grid: grid, isoValue: 0, insideIsAbove: false)
            : SurfaceNets(grid: grid, isoValue: grid.maxValue * fogIsoFraction, insideIsAbove: true)
        let mesh = surfaceNets.extract()
        let colors = grids.color.map { sampleColors($0, mesh) }
        return Surface(mesh: mesh, colors: colors, gridName: grid.name, colorGridName: grids.color?.name,
                       isLevelSet: grid.isLevelSet)
    }

    private static func sampleColors(_ colorGrid: VdbGrid, _ mesh: SurfaceNets.Mesh) -> [Float] {
        var colors = [Float](repeating: 0, count: mesh.vertexCount * 4)
        let vertices = mesh.vertices
        for i in 0..<mesh.vertexCount {
            let color = colorGrid.sample3(Double(vertices[i * 3]), Double(vertices[i * 3 + 1]), Double(vertices[i * 3 + 2]))
            for c in 0..<3 {
                colors[i * 4 + c] = linearToSrgb(color[c])
            }
            colors[i * 4 + 3] = 1
        }
        return colors
    }

    /// Converts a linear color component to sRGB.
    static func linearToSrgb(_ value: Float) -> Float {
        let c = min(max(value, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055
    }
}
