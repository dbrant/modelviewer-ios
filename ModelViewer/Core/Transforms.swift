//
//  Transforms.swift
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

/// Double-precision affine transforms, as 4x4 column-major matrices (16 Doubles), for placing the
/// parts of scenes (FBX and glTF) in the model's coordinates.
enum Transforms {
    private static let rotationOrders: [[Int]] = [
        [0, 1, 2], [0, 2, 1], [1, 2, 0], [1, 0, 2], [2, 0, 1], [2, 1, 0] // XYZ, XZY, YZX, YXZ, ZXY, ZYX
    ]

    static func identity() -> [Double] {
        var m = [Double](repeating: 0, count: 16)
        m[0] = 1; m[5] = 1; m[10] = 1; m[15] = 1
        return m
    }

    static func translation(_ t: [Double]) -> [Double] {
        var m = identity()
        m[12] = t[0]; m[13] = t[1]; m[14] = t[2]
        return m
    }

    static func scaling(_ s: [Double]) -> [Double] {
        var m = identity()
        m[0] = s[0]; m[5] = s[1]; m[10] = s[2]
        return m
    }

    /// Rotation by Euler angles (in degrees) about the X, Y, and Z axes, applied in the given order (as in FbxEuler::EOrder).
    static func rotation(_ angles: [Double], order: Int) -> [Double] {
        var result = identity()
        let axes = (order >= 0 && order < rotationOrders.count) ? rotationOrders[order] : rotationOrders[0]
        for axis in axes {
            let a = angles[axis] * .pi / 180
            let c = cos(a)
            let s = sin(a)
            var r = identity()
            switch axis {
            case 0: r[5] = c; r[6] = s; r[9] = -s; r[10] = c
            case 1: r[0] = c; r[2] = -s; r[8] = s; r[10] = c
            default: r[0] = c; r[1] = s; r[4] = -s; r[5] = c
            }
            result = multiply(r, result)
        }
        return result
    }

    /// Rotation by a quaternion (which is normalized, in case it isn't already).
    static func rotation(x: Double, y: Double, z: Double, w: Double) -> [Double] {
        let length = (x * x + y * y + z * z + w * w).squareRoot()
        if length == 0 || !length.isFinite {
            return identity()
        }
        let qx = x / length, qy = y / length, qz = z / length, qw = w / length
        var m = identity()
        m[0] = 1 - 2 * (qy * qy + qz * qz)
        m[1] = 2 * (qx * qy + qw * qz)
        m[2] = 2 * (qx * qz - qw * qy)
        m[4] = 2 * (qx * qy - qw * qz)
        m[5] = 1 - 2 * (qx * qx + qz * qz)
        m[6] = 2 * (qy * qz + qw * qx)
        m[8] = 2 * (qx * qz + qw * qy)
        m[9] = 2 * (qy * qz - qw * qx)
        m[10] = 1 - 2 * (qx * qx + qy * qy)
        return m
    }

    static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var result = [Double](repeating: 0, count: 16)
        for col in 0..<4 {
            for row in 0..<4 {
                var sum = 0.0
                for k in 0..<4 {
                    sum += a[k * 4 + row] * b[col * 4 + k]
                }
                result[col * 4 + row] = sum
            }
        }
        return result
    }

    static func transpose(_ m: [Double]) -> [Double] {
        (0..<16).map { m[($0 % 4) * 4 + $0 / 4] }
    }

    /// The determinant of the upper 3x3 part of the transform that starts at the given offset.
    static func determinant(_ m: [Double], _ o: Int = 0) -> Double {
        m[o] * (m[o + 5] * m[o + 10] - m[o + 9] * m[o + 6]) - m[o + 4] * (m[o + 1] * m[o + 10] - m[o + 9] * m[o + 2]) +
            m[o + 8] * (m[o + 1] * m[o + 6] - m[o + 5] * m[o + 2])
    }

    /// The cofactor matrix of the upper 3x3 part of the transform (column-major, as is the result).
    static func cofactors(_ m: [Double], _ o: Int, _ out: inout [Double], _ offset: Int) {
        out[offset] = m[o + 5] * m[o + 10] - m[o + 6] * m[o + 9]
        out[offset + 1] = m[o + 6] * m[o + 8] - m[o + 4] * m[o + 10]
        out[offset + 2] = m[o + 4] * m[o + 9] - m[o + 5] * m[o + 8]
        out[offset + 3] = m[o + 2] * m[o + 9] - m[o + 1] * m[o + 10]
        out[offset + 4] = m[o] * m[o + 10] - m[o + 2] * m[o + 8]
        out[offset + 5] = m[o + 1] * m[o + 8] - m[o] * m[o + 9]
        out[offset + 6] = m[o + 1] * m[o + 6] - m[o + 2] * m[o + 5]
        out[offset + 7] = m[o + 2] * m[o + 4] - m[o] * m[o + 6]
        out[offset + 8] = m[o] * m[o + 5] - m[o + 1] * m[o + 4]
    }

    /// The inverse transpose of the upper 3x3 part of the transform (as 9 Doubles, column-major),
    /// which transforms normals (up to their length, since they're normalized anyway).
    static func normalMatrix(_ m: [Double], _ o: Int, _ out: inout [Double], _ offset: Int) {
        // The cofactor matrix is the inverse transpose, multiplied by the determinant.
        cofactors(m, o, &out, offset)
        if determinant(m, o) < 0 {
            for i in offset..<(offset + 9) {
                out[i] = -out[i]
            }
        }
    }

    /// The inverse of an affine transform, or nil if it has none.
    static func inverse(_ m: [Double]) -> [Double]? {
        let det = determinant(m)
        if det == 0 || !det.isFinite {
            return nil
        }
        // The inverse of the 3x3 part is the transpose of its cofactor matrix, divided by the determinant.
        var c = [Double](repeating: 0, count: 9)
        cofactors(m, 0, &c, 0)
        var result = identity()
        for col in 0..<3 {
            for row in 0..<3 {
                result[col * 4 + row] = c[row * 3 + col] / det
            }
        }
        for row in 0..<3 {
            result[12 + row] = -(result[row] * m[12] + result[4 + row] * m[13] + result[8 + row] * m[14])
        }
        return result
    }

    static func transformPoint(_ m: [Double], _ o: Int, _ x: Double, _ y: Double, _ z: Double, _ out: inout [Double], _ offset: Int) {
        out[offset] = m[o] * x + m[o + 4] * y + m[o + 8] * z + m[o + 12]
        out[offset + 1] = m[o + 1] * x + m[o + 5] * y + m[o + 9] * z + m[o + 13]
        out[offset + 2] = m[o + 2] * x + m[o + 6] * y + m[o + 10] * z + m[o + 14]
    }

    /// Transforms a normal by a 3x3 normal matrix (as from `normalMatrix`), and normalizes it.
    static func transformNormal(_ m: [Double], _ o: Int, _ normals: [Double], _ index: Int, _ out: inout [Double], _ offset: Int) {
        let x = normals[index], y = normals[index + 1], z = normals[index + 2]
        let nx = m[o] * x + m[o + 3] * y + m[o + 6] * z
        let ny = m[o + 1] * x + m[o + 4] * y + m[o + 7] * z
        let nz = m[o + 2] * x + m[o + 5] * y + m[o + 8] * z
        let length = (nx * nx + ny * ny + nz * nz).squareRoot()
        let scale = length > 0 ? 1 / length : 0
        out[offset] = nx * scale
        out[offset + 1] = ny * scale
        out[offset + 2] = nz * scale
    }

    /// Sets the normal of every corner of a triangle (9 coordinates in `p`) to that of its face.
    static func faceNormal(_ p: [Double], _ out: inout [Double]) {
        let e1x = p[3] - p[0], e1y = p[4] - p[1], e1z = p[5] - p[2]
        let e2x = p[6] - p[0], e2y = p[7] - p[1], e2z = p[8] - p[2]
        let nx = e1y * e2z - e1z * e2y
        let ny = e1z * e2x - e1x * e2z
        let nz = e1x * e2y - e1y * e2x
        let length = (nx * nx + ny * ny + nz * nz).squareRoot()
        let scale = length > 0 ? 1 / length : 0
        for c in 0..<3 {
            out[c * 3] = nx * scale
            out[c * 3 + 1] = ny * scale
            out[c * 3 + 2] = nz * scale
        }
    }

    /// The (unnormalized) normal of the triangle with the given corners, by the right-hand rule.
    static func calculateNormal(_ x1: Float, _ y1: Float, _ z1: Float,
                                _ x2: Float, _ y2: Float, _ z2: Float,
                                _ x3: Float, _ y3: Float, _ z3: Float) -> SIMD3<Float> {
        SIMD3((y2 - y1) * (z3 - z1) - (y3 - y1) * (z2 - z1),
              (z2 - z1) * (x3 - x1) - (x2 - x1) * (z3 - z1),
              (x2 - x1) * (y3 - y1) - (x3 - x1) * (y2 - y1))
    }
}
