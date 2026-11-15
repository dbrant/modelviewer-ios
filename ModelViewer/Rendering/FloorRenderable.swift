//
//  FloorRenderable.swift
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

import Metal
import simd

/// A floor with grid lines, beneath the model.
@MainActor
final class FloorRenderable {
    private let vertexBuffer: MTLBuffer?
    private let vertexCount: Int
    private let extent: Float
    private let floorColor = SIMD4<Float>(0.2, 0.2, 0.2, 0.5)
    private let lineColor = SIMD4<Float>(0.6, 0.6, 0.6, 0.5)

    /// Height of the floor.
    var offsetY: Float = 0

    init(device: MTLDevice, boundSize: Float) {
        let e = boundSize * 5
        extent = e
        // The grid lines on the floor are rendered procedurally and large polygons cause floating point
        // precision problems on some architectures. So we split the floor into 4 quadrants.
        let coords: [Float] = [
            // +X, +Z quadrant
            e, 0, 0, 0, 0, 0, 0, 0, e,
            e, 0, 0, 0, 0, e, e, 0, e,
            // -X, +Z quadrant
            0, 0, 0, -e, 0, 0, -e, 0, e,
            0, 0, 0, -e, 0, e, 0, 0, e,
            // +X, -Z quadrant
            e, 0, -e, 0, 0, -e, 0, 0, 0,
            e, 0, -e, 0, 0, 0, e, 0, 0,
            // -X, -Z quadrant
            0, 0, -e, -e, 0, -e, -e, 0, 0,
            0, 0, -e, -e, 0, 0, 0, 0, 0,
        ]
        vertexCount = coords.count / 3
        vertexBuffer = device.makeBuffer(bytes: coords, length: coords.count * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    func draw(_ context: RenderContext) {
        guard let vertexBuffer else {
            return
        }
        let model = MatrixUtil.translation(SIMD3(0, offsetY, 0))
        var uniforms = FloorUniforms(
            model: model,
            mvp: context.projectionMatrix * context.viewMatrix * model,
            floorColor: floorColor,
            lineColor: lineColor,
            maxDepth: extent,
            gridUnit: extent / 75,
            lineWidth: 0.1)
        let encoder = context.encoder
        encoder.setRenderPipelineState(context.pipelines.floor)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: Int(BufferIndex.positions.rawValue))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FloorUniforms>.stride, index: Int(BufferIndex.uniforms.rawValue))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FloorUniforms>.stride, index: Int(BufferIndex.uniforms.rawValue))
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
    }
}
