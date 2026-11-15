//
//  MatrixUtil.swift
//  ModelViewer
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

/// Single-precision matrix helpers for rendering, equivalent to those of android.opengl.Matrix
/// (column-major, right-handed, with OpenGL's clip space conventions).
enum MatrixUtil {
    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t.x, t.y, t.z, 1)
        return m
    }

    static func scale(_ s: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(s.x, s.y, s.z, 1))
    }

    /// Rotation by the given angle (in degrees) about the given axis, as with Matrix.setRotateM.
    static func rotation(degrees: Float, axis: SIMD3<Float>) -> simd_float4x4 {
        if degrees == 0 {
            return matrix_identity_float4x4
        }
        return simd_float4x4(simd_quatf(angle: degrees * .pi / 180, axis: simd_normalize(axis)))
    }

    /// A view matrix that looks from the eye toward the center, as with Matrix.setLookAtM.
    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(center - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        let rotation = simd_float4x4(columns: (
            SIMD4(s.x, u.x, -f.x, 0),
            SIMD4(s.y, u.y, -f.y, 0),
            SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(0, 0, 0, 1)))
        return rotation * translation(-eye)
    }

    /// A perspective projection with OpenGL's clip space (depth from -1 to 1), as with Matrix.perspectiveM.
    /// The vertex shaders convert the depth to Metal's range.
    static func perspective(fovyDegrees: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let f = 1 / tan(fovyDegrees * .pi / 360)
        let rangeReciprocal = 1 / (near - far)
        return simd_float4x4(columns: (
            SIMD4(f / aspect, 0, 0, 0),
            SIMD4(0, f, 0, 0),
            SIMD4(0, 0, (far + near) * rangeReciprocal, -1),
            SIMD4(0, 0, 2 * far * near * rangeReciprocal, 0)))
    }
}
