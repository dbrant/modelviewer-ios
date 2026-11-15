//
//  MeshRenderable.swift
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
import os

/// GPU resources of a mesh, and how to draw it: with one color, with its materials, or as points.
@MainActor
final class MeshRenderable: Renderable {
    private static let logger = Logger(subsystem: "com.dmitrybrant.modelviewer", category: "MeshRenderable")
    /// Limits texture memory, even when the GPU supports larger textures.
    private static let maxTextureSize = 4096

    private let positions: MTLBuffer
    private let normals: MTLBuffer?
    private let colors: MTLBuffer?
    private let texCoords: MTLBuffer?
    private let indices: MTLBuffer?
    private let elementCount: Int
    private let isPointCloud: Bool
    private let hasMaterials: Bool
    private let parts: [MeshPart]
    private var textures: [Material: MTLTexture] = [:]
    private var transparentTextures = Set<Material>()

    init(device: MTLDevice, mesh: MeshModel) throws {
        func makeBuffer<T>(_ array: [T]?) -> MTLBuffer? {
            guard let array, !array.isEmpty else {
                return nil
            }
            return array.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        }
        guard let positions = makeBuffer(mesh.vertices) else {
            throw ModelError("The model has no vertices.")
        }
        self.positions = positions
        normals = makeBuffer(mesh.normals)
        colors = makeBuffer(mesh.colors)
        texCoords = makeBuffer(mesh.texCoords)
        indices = makeBuffer(mesh.indices)
        elementCount = mesh.elementCount
        isPointCloud = mesh.isPointCloud
        hasMaterials = mesh.hasMaterials
        // A mesh without parts is drawn with one default material.
        parts = mesh.parts.isEmpty
            ? [MeshPart(material: Material.forVertexColors(), first: 0, count: mesh.elementCount)]
            : mesh.parts

        if texCoords != nil {
            let maxSize = min(Self.maxTextureSize, device.supportsFamily(.apple3) ? 16384 : 8192)
            for material in Set(parts.map(\.material)) {
                guard let data = material.diffuseTexture else {
                    continue
                }
                do {
                    let decoded = try TextureLoader.load(device: device, data: data, maxSize: maxSize)
                    textures[material] = decoded.texture
                    if decoded.hasTransparency {
                        transparentTextures.insert(material)
                    }
                } catch {
                    Self.logger.warning("Unable to decode texture \(material.diffuseTextureName ?? "", privacy: .public): \(error.localizedDescription)")
                }
            }
        }
    }

    func draw(_ context: RenderContext, modelMatrix: simd_float4x4) {
        let encoder = context.encoder
        let mvp = context.projectionMatrix * context.viewMatrix * modelMatrix
        let light = context.light
        var uniforms = MeshUniforms(
            mvp: mvp,
            lightPosition: light.positionInEyeSpace,
            ambientColor: light.ambientColor,
            diffuseColor: light.diffuseColor,
            specularColor: light.specularColor,
            hasColors: colors != nil ? 1 : 0,
            hasTexCoords: texCoords != nil ? 1 : 0,
            pointSize: context.pointSize)
        let empty = context.pipelines.emptyBuffer
        encoder.setVertexBuffer(positions, offset: 0, index: Int(BufferIndex.positions.rawValue))
        encoder.setVertexBuffer(normals ?? empty, offset: 0, index: Int(BufferIndex.normals.rawValue))
        encoder.setVertexBuffer(colors ?? empty, offset: 0, index: Int(BufferIndex.colors.rawValue))
        encoder.setVertexBuffer(texCoords ?? empty, offset: 0, index: Int(BufferIndex.texCoords.rawValue))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MeshUniforms>.stride, index: Int(BufferIndex.uniforms.rawValue))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MeshUniforms>.stride, index: Int(BufferIndex.uniforms.rawValue))

        if isPointCloud {
            uniforms.diffuseColor = SIMD4(1, 1, 1, 1)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MeshUniforms>.stride, index: Int(BufferIndex.uniforms.rawValue))
            encoder.setRenderPipelineState(context.pipelines.points)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: positions.length / (3 * MemoryLayout<Float>.stride))
            return
        }
        guard normals != nil else {
            return
        }

        if !hasMaterials {
            encoder.setRenderPipelineState(context.pipelines.singleLight)
            drawRange(encoder, first: 0, count: elementCount)
            return
        }

        encoder.setFragmentSamplerState(context.pipelines.textureSampler, index: 0)
        // Draw opaque parts first, and then blend transparent parts over them.
        encoder.setRenderPipelineState(context.pipelines.materialOpaque)
        for part in parts where !isTransparent(part.material) {
            drawPart(encoder, context, part)
        }
        if parts.contains(where: { isTransparent($0.material) }) {
            encoder.setRenderPipelineState(context.pipelines.materialBlended)
            encoder.setDepthStencilState(context.pipelines.depthTestOnly)
            for part in parts where isTransparent(part.material) {
                drawPart(encoder, context, part)
            }
            encoder.setDepthStencilState(context.pipelines.depthWrite)
        }
    }

    private func isTransparent(_ material: Material) -> Bool {
        switch material.alphaMode {
        case .auto: material.opacity < 1 || transparentTextures.contains(material)
        case .blend: true
        case .opaque, .mask: false
        }
    }

    private func drawPart(_ encoder: MTLRenderCommandEncoder, _ context: RenderContext, _ part: MeshPart) {
        let material = part.material
        let texture = textures[material]
        var uniforms = MaterialUniforms(
            diffuseColor: SIMD4(material.diffuseColor, material.opacity),
            specularColor: SIMD4(material.specularColor, 0),
            emissiveColor: SIMD4(material.emissiveColor, 0),
            textureScale: material.textureScale,
            textureOffset: material.textureOffset,
            shininess: min(max(material.shininess, 1), 1000),
            lighting: Int32(material.lighting.rawValue),
            useTexture: texture != nil ? 1 : 0,
            alphaCutoff: material.alphaMode == .mask ? material.alphaCutoff : 0,
            opaque: (material.alphaMode == .opaque || material.alphaMode == .mask) ? 1 : 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MaterialUniforms>.stride, index: Int(BufferIndex.material.rawValue))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MaterialUniforms>.stride, index: Int(BufferIndex.material.rawValue))
        encoder.setFragmentTexture(texture ?? context.pipelines.whiteTexture, index: 0)
        drawRange(encoder, first: part.first, count: part.count)
    }

    private func drawRange(_ encoder: MTLRenderCommandEncoder, first: Int, count: Int) {
        guard count > 0, first >= 0, first + count <= elementCount else {
            return
        }
        if let indices {
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: count, indexType: .uint32,
                                          indexBuffer: indices, indexBufferOffset: first * MemoryLayout<UInt32>.stride)
        } else {
            encoder.drawPrimitives(type: .triangle, vertexStart: first, vertexCount: count)
        }
    }
}
