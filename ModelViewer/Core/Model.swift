//
//  Model.swift
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
import simd

/// How a model's own coordinate system is turned to face the viewer, with its "up" axis pointing up.
enum ModelOrientation: Sendable {
    /// The Y axis is up (OBJ, PLY, FBX, glTF). The model is turned 180° about Y to face the camera.
    case yUp
    /// The Z axis is up (STL, 3MF), as is usual for 3D printing.
    case zUp
    /// The model is shown in its own coordinates, with the Y axis up (VDB).
    case native

    /// Rotations (in degrees) about the X, Y, and Z axes, which are applied in that order.
    var rotation: SIMD3<Float> {
        switch self {
        case .yUp: SIMD3(0, 180, 0)
        case .zUp: SIMD3(-90, 0, 180)
        case .native: SIMD3(0, 0, 0)
        }
    }
}

/// Base class of everything that can be shown in the viewer.
///
/// Models are created on a background thread by a format's parser, and are not modified after
/// they're handed to the renderer (except by `setup(boundSize:)`, which the renderer calls once).
class Model: @unchecked Sendable {
    var title = ""

    // Center of mass, populated by subclasses.
    var centerMassX: Float = 0
    var centerMassY: Float = 0
    var centerMassZ: Float = 0

    // Bounds of the model in its own coordinates, populated by subclasses (usually via adjustMaxMin).
    var maxX = -Float.greatestFiniteMagnitude
    var maxY = -Float.greatestFiniteMagnitude
    var maxZ = -Float.greatestFiniteMagnitude
    var minX = Float.greatestFiniteMagnitude
    var minY = Float.greatestFiniteMagnitude
    var minZ = Float.greatestFiniteMagnitude

    /// Height of the bottom of the model, relative to its center, once it's scaled to its bounds.
    private(set) var floorOffset: Float = 0

    /// Radius of a sphere around the center of mass that contains the whole model, once it's scaled to its bounds.
    private(set) var boundingRadius: Float = 0

    /// Transform from the model's coordinates to world coordinates, where it's centered and scaled to fit its bounds.
    private(set) var modelMatrix = matrix_identity_float4x4

    /// How the model is oriented; subclasses override this according to their format's conventions.
    var orientation: ModelOrientation { .yUp }

    /// Brief description of what's shown, if there's more to say than the title (such as which grid of a volume).
    var subtitle: String? { nil }

    /// Computes the model matrix, so that the model fits within a cube of the given size, centered at the origin.
    func setup(boundSize: Float) {
        let rotation = orientation.rotation
        var m = matrix_identity_float4x4
        m = m * MatrixUtil.rotation(degrees: rotation.x, axis: SIMD3(1, 0, 0))
        m = m * MatrixUtil.rotation(degrees: rotation.y, axis: SIMD3(0, 1, 0))
        m = m * MatrixUtil.rotation(degrees: rotation.z, axis: SIMD3(0, 0, 1))
        let boundScale = getBoundScale(boundSize)
        if boundScale != 0 && boundScale.isFinite {
            let s = 1 / boundScale
            m = m * MatrixUtil.scale(SIMD3(s, s, s))
        }
        m = m * MatrixUtil.translation(SIMD3(-centerMassX, -centerMassY, -centerMassZ))
        modelMatrix = m

        let scale = (boundScale != 0 && boundScale.isFinite) ? boundScale : 1
        let dx = max(maxX - centerMassX, centerMassX - minX)
        let dy = max(maxY - centerMassY, centerMassY - minY)
        let dz = max(maxZ - centerMassZ, centerMassZ - minZ)
        let radius = (dx * dx + dy * dy + dz * dz).squareRoot() / scale
        boundingRadius = radius.isFinite ? radius : 0

        let floor: Float = switch orientation {
        case .zUp: (minZ - centerMassZ) / scale
        case .yUp, .native: (minY - centerMassY) / scale
        }
        floorOffset = floor.isFinite ? floor : 0
    }

    final func adjustMaxMin(_ x: Float, _ y: Float, _ z: Float) {
        if x > maxX { maxX = x }
        if y > maxY { maxY = y }
        if z > maxZ { maxZ = z }
        if x < minX { minX = x }
        if y < minY { minY = y }
        if z < minZ { minZ = z }
    }

    /// The factor by which the model is larger than the given bound size, along its largest dimension.
    final func getBoundScale(_ boundSize: Float) -> Float {
        let scaleX = (maxX - minX) / boundSize
        let scaleY = (maxY - minY) / boundSize
        let scaleZ = (maxZ - minZ) / boundSize
        let scale = max(scaleX, scaleY, scaleZ)
        return scale.isFinite ? scale : 0
    }
}
