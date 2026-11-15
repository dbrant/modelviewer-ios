//
//  VdbVolumeModel.swift
//  ModelViewer
//
//  An OpenVDB fog volume (such as smoke, clouds, or fire), which is rendered as a translucent
//  volume, by ray marching through a 3D texture of its density (see VolumeTexture). The texture
//  is drawn on the faces of a box (a unit cube in texture coordinates), which `textureMatrix`
//  places in the model's coordinates.
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
import simd

final class VdbVolumeModel: Model, @unchecked Sendable {
    /// The smoke of fire is sooty, which makes it much darker than a cloud.
    static let smokeAlbedo: Float = 0.5

    /// Brightness of the glow of the hottest parts of a volume, relative to the light that it reflects.
    static let glowBrightness: Float = 4

    let volume: VolumeTexture
    let gridName: String
    let colorGridName: String?
    let glowGridName: String?

    /// Transform from texture coordinates (0 to 1 across the texture) to the model's coordinates.
    let textureMatrix: simd_float4x4

    /// Whether the texture's transform mirrors it, which turns the faces of its box inside out.
    let isMirrored: Bool

    override var orientation: ModelOrientation { .native }

    override var subtitle: String? {
        var parts = [gridName]
        if let colorGridName {
            parts.append("color: \(colorGridName)")
        }
        if let glowGridName {
            parts.append("glow: \(glowGridName)")
        }
        return parts.joined(separator: " · ")
    }

    init(volume: VolumeTexture, gridName: String, colorGridName: String?, glowGridName: String?) {
        self.volume = volume
        self.gridName = gridName
        self.colorGridName = colorGridName
        self.glowGridName = glowGridName
        self.textureMatrix = Self.textureMatrix(for: volume)
        self.isMirrored = VdbGrid.determinant3x3(volume.textureToWorld) < 0
        super.init()
        centerMassX = Float(volume.centroid[0])
        centerMassY = Float(volume.centroid[1])
        centerMassZ = Float(volume.centroid[2])
        let m = volume.textureToWorld
        for n in 0..<8 {
            let corner = VolumeTexture.transform(m, Double(n & 1), Double((n >> 1) & 1), Double((n >> 2) & 1))
            adjustMaxMin(Float(corner[0]), Float(corner[1]), Float(corner[2]))
        }
    }

    /// The transform from texture coordinates to model coordinates of the given texture (which may
    /// be a downsampled version of `volume`, whose box can be slightly larger).
    static func textureMatrix(for texture: VolumeTexture) -> simd_float4x4 {
        let m = texture.textureToWorld
        return simd_float4x4(columns: (
            SIMD4(Float(m[0]), Float(m[1]), Float(m[2]), 0),
            SIMD4(Float(m[3]), Float(m[4]), Float(m[5]), 0),
            SIMD4(Float(m[6]), Float(m[7]), Float(m[8]), 0),
            SIMD4(Float(m[9]), Float(m[10]), Float(m[11]), 1)))
    }

    /// The linear part of the texture's transform (texture coordinates to world units), for
    /// measuring the distance that light travels through the volume.
    static func textureToWorld3x3(for texture: VolumeTexture) -> simd_float3x3 {
        let m = texture.textureToWorld
        return simd_float3x3(columns: (
            SIMD3(Float(m[0]), Float(m[1]), Float(m[2])),
            SIMD3(Float(m[3]), Float(m[4]), Float(m[5])),
            SIMD3(Float(m[6]), Float(m[7]), Float(m[8]))))
    }

    /// The faces of the unit cube, as quads of corners, where corner n is at
    /// ((n >> 2) & 1, (n >> 1) & 1, n & 1), wound counterclockwise when seen from outside.
    private static let cubeFaces: [[Int]] = [
        [0b000, 0b001, 0b011, 0b010], // -x
        [0b101, 0b100, 0b110, 0b111], // +x
        [0b000, 0b100, 0b101, 0b001], // -y
        [0b011, 0b111, 0b110, 0b010], // +y
        [0b000, 0b010, 0b110, 0b100], // -z
        [0b001, 0b101, 0b111, 0b011]] // +z

    /// Vertices of the triangles of the unit cube (3 floats each, 36 vertices), facing outward.
    static let cubeVertices: [Float] = {
        var vertices: [Float] = []
        for quad in cubeFaces {
            for corner in [quad[0], quad[1], quad[2], quad[0], quad[2], quad[3]] {
                vertices.append(Float((corner >> 2) & 1))
                vertices.append(Float((corner >> 1) & 1))
                vertices.append(Float(corner & 1))
            }
        }
        return vertices
    }()
}
