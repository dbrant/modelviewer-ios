//
//  Pipelines.swift
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

/// The render pipelines and depth states that are used to draw everything.
@MainActor
final class Pipelines {
    let singleLight: MTLRenderPipelineState
    let materialOpaque: MTLRenderPipelineState
    /// Blends transparent materials over what's behind them.
    let materialBlended: MTLRenderPipelineState
    let points: MTLRenderPipelineState
    let floor: MTLRenderPipelineState
    /// Blends volumes (with premultiplied alpha) over what's behind them.
    let volume: MTLRenderPipelineState

    let depthWrite: MTLDepthStencilState
    let depthTestOnly: MTLDepthStencilState
    let depthDisabled: MTLDepthStencilState

    let textureSampler: MTLSamplerState
    /// A small buffer to bind in place of vertex attributes that a mesh doesn't have.
    let emptyBuffer: MTLBuffer
    /// A 1x1 white texture, to bind in place of textures that a material doesn't have.
    let whiteTexture: MTLTexture
    let empty3DTexture: MTLTexture

    init(device: MTLDevice) throws {
        guard let library = device.makeDefaultLibrary() else {
            throw ModelError("Unable to load shaders.")
        }

        func pipeline(_ vertex: String, _ fragment: String, blend: Blend = .none) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.rasterSampleCount = Renderer.sampleCount
            descriptor.depthAttachmentPixelFormat = Renderer.depthPixelFormat
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = Renderer.colorPixelFormat
            switch blend {
            case .none:
                break
            case .alpha:
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = .sourceAlpha
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.sourceAlphaBlendFactor = .sourceAlpha
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .premultiplied:
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = .one
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.sourceAlphaBlendFactor = .one
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        singleLight = try pipeline("singleLightVertex", "singleLightFragment")
        materialOpaque = try pipeline("materialVertex", "materialFragment")
        materialBlended = try pipeline("materialVertex", "materialFragment", blend: .alpha)
        points = try pipeline("pointVertex", "pointFragment")
        floor = try pipeline("floorVertex", "floorFragment")
        volume = try pipeline("volumeVertex", "volumeFragment", blend: .premultiplied)

        func depthState(compare: MTLCompareFunction, write: Bool) throws -> MTLDepthStencilState {
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.depthCompareFunction = compare
            descriptor.isDepthWriteEnabled = write
            guard let state = device.makeDepthStencilState(descriptor: descriptor) else {
                throw ModelError("Unable to create depth state.")
            }
            return state
        }
        depthWrite = try depthState(compare: .less, write: true)
        depthTestOnly = try depthState(compare: .less, write: false)
        depthDisabled = try depthState(compare: .always, write: false)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        samplerDescriptor.maxAnisotropy = 4
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor),
              let buffer = device.makeBuffer(length: 64, options: .storageModeShared) else {
            throw ModelError("Unable to create GPU resources.")
        }
        textureSampler = sampler
        emptyBuffer = buffer

        let white: [UInt8] = [255, 255, 255, 255]
        whiteTexture = try TextureLoader.makeTexture(device: device, rgba: white, width: 1, height: 1, mipmapped: false)

        let descriptor3D = MTLTextureDescriptor()
        descriptor3D.textureType = .type3D
        descriptor3D.pixelFormat = .rgba8Unorm
        descriptor3D.width = 1
        descriptor3D.height = 1
        descriptor3D.depth = 1
        descriptor3D.usage = .shaderRead
        guard let texture3D = device.makeTexture(descriptor: descriptor3D) else {
            throw ModelError("Unable to create GPU resources.")
        }
        texture3D.replace(region: MTLRegionMake3D(0, 0, 0, 1, 1, 1), mipmapLevel: 0, slice: 0,
                          withBytes: white, bytesPerRow: 4, bytesPerImage: 4)
        empty3DTexture = texture3D
    }

    private enum Blend {
        case none
        case alpha
        case premultiplied
    }
}
