//
//  VolumeRenderable.swift
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

import Metal
import simd

/// GPU resources of a fog volume, which is drawn by ray marching through a 3D texture of its density.
@MainActor
final class VolumeRenderable: Renderable {
    /// The largest dimension of a 3D texture that Apple GPUs support.
    private static let max3DTextureSize = 2048

    private let model: VdbVolumeModel
    private let volumeTexture: MTLTexture
    private let colorTexture: MTLTexture?
    private let fireRampTexture: MTLTexture?
    private let cubeBuffer: MTLBuffer
    private let textureSize: SIMD3<Float>
    /// Transform from texture coordinates to the model's coordinates.
    private let textureMatrix: simd_float4x4
    /// The linear part of `textureMatrix`.
    private let textureToWorld: simd_float3x3
    private let isMirrored: Bool

    init(device: MTLDevice, model: VdbVolumeModel) throws {
        self.model = model
        // Reduce the resolution of a volume that's too large for the GPU.
        var texture = model.volume
        while max(texture.sizeX, texture.sizeY, texture.sizeZ) > Self.max3DTextureSize {
            texture = texture.downsampled()
        }

        let texelCount = texture.sizeX * texture.sizeY * texture.sizeZ
        if texture.channels == 3 {
            // There's no 3-channel 8-bit format, so the texels are padded to 4 channels.
            var padded = [UInt8](repeating: 0, count: texelCount * 4)
            texture.texels.withUnsafeBufferPointer { src in
                padded.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<texelCount {
                        dst[i * 4] = src[i * 3]
                        dst[i * 4 + 1] = src[i * 3 + 1]
                        dst[i * 4 + 2] = src[i * 3 + 2]
                    }
                }
            }
            volumeTexture = try Self.make3DTexture(device: device, texture: texture, bytes: padded, format: .rgba8Unorm, bytesPerTexel: 4)
        } else {
            volumeTexture = try Self.make3DTexture(device: device, texture: texture, bytes: texture.texels, format: .rg8Unorm, bytesPerTexel: 2)
        }
        if let color = texture.color {
            var padded = [UInt8](repeating: 255, count: texelCount * 4)
            color.withUnsafeBufferPointer { src in
                padded.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<texelCount {
                        dst[i * 4] = src[i * 3]
                        dst[i * 4 + 1] = src[i * 3 + 1]
                        dst[i * 4 + 2] = src[i * 3 + 2]
                    }
                }
            }
            colorTexture = try Self.make3DTexture(device: device, texture: texture, bytes: padded, format: .rgba8Unorm_srgb, bytesPerTexel: 4)
        } else {
            colorTexture = nil
        }
        fireRampTexture = texture.glow != .none ? try Self.makeFireRamp(device: device) : nil

        let cube = VdbVolumeModel.cubeVertices
        guard let buffer = device.makeBuffer(bytes: cube, length: cube.count * MemoryLayout<Float>.stride, options: .storageModeShared) else {
            throw ModelError("Unable to create GPU resources.")
        }
        cubeBuffer = buffer

        textureSize = SIMD3(Float(texture.sizeX), Float(texture.sizeY), Float(texture.sizeZ))
        // The texture's box may be slightly larger than the volume's, if it was downsampled.
        textureMatrix = VdbVolumeModel.textureMatrix(for: texture)
        textureToWorld = VdbVolumeModel.textureToWorld3x3(for: texture)
        isMirrored = simd_determinant(textureToWorld) < 0
    }

    private static func make3DTexture(device: MTLDevice, texture: VolumeTexture, bytes: [UInt8], format: MTLPixelFormat,
                                      bytesPerTexel: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = format
        descriptor.width = texture.sizeX
        descriptor.height = texture.sizeY
        descriptor.depth = texture.sizeZ
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let result = device.makeTexture(descriptor: descriptor) else {
            throw ModelError("Unable to create a \(texture.sizeX)×\(texture.sizeY)×\(texture.sizeZ) texture.")
        }
        bytes.withUnsafeBytes { p in
            result.replace(region: MTLRegionMake3D(0, 0, 0, texture.sizeX, texture.sizeY, texture.sizeZ), mipmapLevel: 0, slice: 0,
                           withBytes: p.baseAddress!, bytesPerRow: texture.sizeX * bytesPerTexel,
                           bytesPerImage: texture.sizeX * texture.sizeY * bytesPerTexel)
        }
        return result
    }

    private static func makeFireRamp(device: MTLDevice) throws -> MTLTexture {
        let ramp = VolumeTexture.fireRamp
        let width = ramp.count / 3
        var rgba = [UInt8](repeating: 255, count: width * 4)
        for i in 0..<width {
            rgba[i * 4] = ramp[i * 3]
            rgba[i * 4 + 1] = ramp[i * 3 + 1]
            rgba[i * 4 + 2] = ramp[i * 3 + 2]
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: width, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw ModelError("Unable to create texture.")
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, 1), mipmapLevel: 0, withBytes: rgba, bytesPerRow: width * 4)
        return texture
    }

    func draw(_ context: RenderContext, modelMatrix: simd_float4x4) {
        let volume = model.volume
        let modelView = context.viewMatrix * modelMatrix * textureMatrix
        // The camera is at the origin of eye space, so its position in texture coordinates is the
        // translation of the inverse transform.
        let inverse = modelView.inverse
        let camera = inverse.columns.3
        let glow = volume.glow
        var uniforms = VolumeUniforms(
            mvp: context.projectionMatrix * modelView,
            cameraPosition: SIMD4(camera.x / camera.w, camera.y / camera.w, camera.z / camera.w, 1),
            textureSize: SIMD4(textureSize, 0),
            textureToWorld: textureToWorld,
            densityScale: volume.maxDensity * VolumeTexture.extinctionScale,
            hasColor: colorTexture != nil ? 1 : 0,
            albedo: glow != .none ? VdbVolumeModel.smokeAlbedo : 1,
            // Hot things glow with the fourth power of their temperature (by the Stefan-Boltzmann law),
            // and flames glow more evenly.
            glowExponent: glow == .thermal ? 4 : 2,
            thermalGlow: glow == .thermal ? VdbVolumeModel.glowBrightness : 0,
            // A ray through all of the flames, packed into a cube at full intensity, would glow at full
            // brightness, whatever the units of the volume.
            flameGlow: glow == .flame && volume.flameLength > 0 ? Float(Double(VdbVolumeModel.glowBrightness) / volume.flameLength) : 0)

        let encoder = context.encoder
        encoder.setRenderPipelineState(context.pipelines.volume)
        // Draw the back faces of the box, so that the rays through the volume are drawn even when
        // the camera is inside it. A transform that mirrors the box turns its faces inside out.
        encoder.setCullMode(isMirrored ? .back : .front)
        // The floor never hides the volume: the floor is drawn only when it's seen from above (from
        // below, its faces are culled), and the volume lies above it. So the volume isn't depth tested.
        encoder.setDepthStencilState(context.pipelines.depthDisabled)
        encoder.setVertexBuffer(cubeBuffer, offset: 0, index: Int(BufferIndex.positions.rawValue))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<VolumeUniforms>.stride, index: Int(BufferIndex.uniforms.rawValue))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VolumeUniforms>.stride, index: Int(BufferIndex.uniforms.rawValue))
        encoder.setFragmentTexture(volumeTexture, index: 0)
        encoder.setFragmentTexture(colorTexture ?? context.pipelines.empty3DTexture, index: 1)
        encoder.setFragmentTexture(fireRampTexture ?? context.pipelines.whiteTexture, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: VdbVolumeModel.cubeVertices.count / 3)
        encoder.setCullMode(.back)
        encoder.setDepthStencilState(context.pipelines.depthWrite)
    }
}
