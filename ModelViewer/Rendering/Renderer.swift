//
//  Renderer.swift
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
import MetalKit
import simd
import os

/// Draws a model (and the floor beneath it) with Metal, from a camera that orbits the model.
@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    static let modelBoundSize: Float = 50
    private static let zNear: Float = 2
    private static let zFar: Float = modelBoundSize * 10
    /// Vertical field of view, in degrees: the height of the view is half of its distance.
    private static let fieldOfView: Float = 2 * atan(0.5) * 180 / .pi
    /// How much closer the near plane is than the closest part of the model or floor, to be safe.
    private static let nearMargin: Float = 0.8
    private static let corners: [SIMD2<Float>] = [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1), SIMD2(1, 1)]
    static let sampleCount = 4
    static let colorPixelFormat = MTLPixelFormat.bgra8Unorm
    static let depthPixelFormat = MTLPixelFormat.depth32Float
    static let clearColor = MTLClearColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1)

    private static let logger = Logger(subsystem: "com.dmitrybrant.modelviewer", category: "Renderer")

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelines: Pipelines
    private let floor: FloorRenderable
    private var renderable: Renderable?

    private(set) var model: Model?

    // Camera
    private var rotateAngleX: Float = 0
    private var rotateAngleY: Float = 0
    private var translateX: Float = 0
    private var translateY: Float = 0
    private var translateZ: Float = 0
    private var aspectRatio: Float = 1
    private var viewMatrix = matrix_identity_float4x4
    private var projectionMatrix = matrix_identity_float4x4
    private let light: Light

    /// Size of points in point clouds, in pixels.
    var pointSize: Float = 3

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(), let pipelines = try? Pipelines(device: device) else {
            return nil
        }
        self.device = device
        self.commandQueue = queue
        self.pipelines = pipelines
        self.floor = FloorRenderable(device: device, boundSize: Self.modelBoundSize)

        // The light stays where it is relative to the camera: it's placed according to the initial view.
        light = Light(positionInWorldSpace: SIMD4(0, 0, Self.modelBoundSize * 10, 1))
        super.init()
        resetView()
        light.applyViewMatrix(MatrixUtil.lookAt(eye: SIMD3(0, 0, -Self.modelBoundSize * 1.5), center: .zero, up: SIMD3(0, 1, 0)))
    }

    /// Sets the model to show, creating its GPU resources, and resets the view.
    func setModel(_ model: Model?) {
        self.model = model
        renderable = nil
        floor.offsetY = 0
        if let model {
            model.setup(boundSize: Self.modelBoundSize)
            floor.offsetY = model.floorOffset
            do {
                renderable = try makeRenderable(for: model)
            } catch {
                Self.logger.error("Unable to prepare model for rendering: \(error.localizedDescription)")
            }
        }
        resetView()
    }

    private func makeRenderable(for model: Model) throws -> Renderable? {
        switch model {
        case let mesh as MeshModel:
            return try MeshRenderable(device: device, mesh: mesh)
        case let volume as VdbVolumeModel:
            return try VolumeRenderable(device: device, model: volume)
        default:
            return nil
        }
    }

    // MARK: - Camera

    func resetView() {
        rotateAngleX = -15
        rotateAngleY = 15
        translateX = 0
        translateY = 0
        translateZ = -Self.modelBoundSize * 1.5
        updateViewMatrix()
    }

    /// Sets the angles (in degrees) by which the view is rotated about the X and Y axes.
    func setRotation(x: Float, y: Float) {
        rotateAngleX = x
        rotateAngleY = y
        updateViewMatrix()
    }

    /// Moves the model sideways (by the given distances in points), and zooms by the given factor.
    func translate(dx: Float, dy: Float, zoom: Float) {
        let translateScaleFactor = Self.modelBoundSize / 200
        translateX += dx * translateScaleFactor
        translateY += dy * translateScaleFactor
        if zoom != 0 && zoom.isFinite {
            translateZ /= zoom
            translateZ = min(max(translateZ, -Self.zFar * 0.9), -Self.zNear)
        }
        updateViewMatrix()
    }

    /// Rotates the model by the given distances that were dragged, in points.
    func rotate(dx: Float, dy: Float) {
        let rotateScaleFactor: Float = 0.5
        rotateAngleX -= dy * rotateScaleFactor
        rotateAngleY += dx * rotateScaleFactor
        updateViewMatrix()
    }

    private func updateViewMatrix() {
        var m = MatrixUtil.lookAt(eye: SIMD3(0, 0, translateZ), center: .zero, up: SIMD3(0, 1, 0))
        m = m * MatrixUtil.translation(SIMD3(-translateX, -translateY, 0))
        m = m * MatrixUtil.rotation(degrees: rotateAngleX, axis: SIMD3(1, 0, 0))
        m = m * MatrixUtil.rotation(degrees: rotateAngleY, axis: SIMD3(0, 1, 0))
        viewMatrix = m
    }

    /// Sets the projection, with its near plane as far from the camera as it can be: just in front of
    /// the model, and of the floor where it's visible. The precision of the depth buffer is spread
    /// mostly near the near plane, so if it's much closer than the model, surfaces of the model that
    /// are very close together can't be told apart in depth, and they flicker through each other.
    private func updateProjection() {
        // The view only moves the model sideways, so its center is at this depth.
        let modelDepth = -translateZ
        // Without its own bounds, a model might extend as far as the corners of its bounding box.
        let radius = model.map { $0.boundingRadius > 0 ? $0.boundingRadius : Self.modelBoundSize * 1.75 } ?? Self.modelBoundSize * 1.75
        let near = max(min(modelDepth - radius, floorDepth()) * Self.nearMargin, Self.zNear)
        projectionMatrix = MatrixUtil.perspective(fovyDegrees: Self.fieldOfView, aspect: aspectRatio, near: near, far: Self.zFar)
    }

    /// The smallest depth of the floor in the view (where it meets a corner of the view), if it's seen from above.
    private func floorDepth() -> Float {
        // The floor's plane (y = floor height), in the camera's coordinates.
        let normal = viewMatrix * SIMD4<Float>(0, 1, 0, 0)
        let point = viewMatrix * SIMD4<Float>(0, model?.floorOffset ?? 0, 0, 1)
        let distance = normal.x * point.x + normal.y * point.y + normal.z * point.z
        // From below, the floor isn't drawn.
        if distance >= 0 {
            return .greatestFiniteMagnitude
        }
        var depth = Float.greatestFiniteMagnitude
        let tanY: Float = 0.5
        for corner in Self.corners {
            // A ray toward the corner, with a depth of 1.
            let dx = corner.x * tanY * aspectRatio
            let dy = corner.y * tanY
            let dot = normal.x * dx + normal.y * dy - normal.z
            if dot < 0 {
                depth = min(depth, distance / dot)
            }
        }
        return depth
    }

    // MARK: - MTKViewDelegate

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated {
            if size.width > 0 && size.height > 0 {
                aspectRatio = Float(size.width / size.height)
            }
        }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            render(in: view)
        }
    }

    private func render(in view: MTKView) {
        let size = view.drawableSize
        if size.width > 0 && size.height > 0 {
            aspectRatio = Float(size.width / size.height)
        }
        guard let passDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }
        encode(encoder, contentScale: Float(view.contentScaleFactor), showFloor: true)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func encode(_ encoder: MTLRenderCommandEncoder, contentScale: Float, showFloor: Bool) {
        updateProjection()
        let context = RenderContext(encoder: encoder, pipelines: pipelines, viewMatrix: viewMatrix,
                                    projectionMatrix: projectionMatrix, light: light,
                                    pointSize: pointSize * contentScale / 2)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.back)
        encoder.setDepthStencilState(pipelines.depthWrite)
        if showFloor {
            floor.draw(context)
        }
        if let model, let renderable {
            renderable.draw(context, modelMatrix: model.modelMatrix)
        }
    }

    // MARK: - Snapshots

    /// Renders the current view into an image of the given size (in pixels), offscreen.
    func snapshot(width: Int, height: Int, contentScale: Float, clearColor: MTLClearColor = Renderer.clearColor,
                  showFloor: Bool = true) -> CGImage? {
        guard width > 0, height > 0 else {
            return nil
        }
        func texture(_ format: MTLPixelFormat, multisampled: Bool, storage: MTLStorageMode) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = .renderTarget
            descriptor.storageMode = storage
            if multisampled {
                descriptor.textureType = .type2DMultisample
                descriptor.sampleCount = Self.sampleCount
            }
            return device.makeTexture(descriptor: descriptor)
        }
        guard let color = texture(Self.colorPixelFormat, multisampled: true, storage: .private),
              let resolved = texture(Self.colorPixelFormat, multisampled: false, storage: .shared),
              let depth = texture(Self.depthPixelFormat, multisampled: true, storage: .private) else {
            return nil
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].resolveTexture = resolved
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = clearColor
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return nil
        }
        let savedAspect = aspectRatio
        aspectRatio = Float(width) / Float(height)
        encode(encoder, contentScale: contentScale, showFloor: showFloor)
        aspectRatio = savedAspect
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { p in
            resolved.getBytes(p.baseAddress!, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            return nil
        }
        // BGRA in memory, with premultiplied alpha.
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// A light, whose position is given in world space and then fixed in eye space.
final class Light {
    private let positionInWorldSpace: SIMD4<Float>
    private(set) var positionInEyeSpace = SIMD4<Float>(0, 0, 0, 1)
    let ambientColor = SIMD4<Float>(0.1, 0.1, 0.4, 1)
    let diffuseColor = SIMD4<Float>(1, 1, 1, 1)
    let specularColor = SIMD4<Float>(1, 1, 1, 0.5)

    init(positionInWorldSpace: SIMD4<Float>) {
        self.positionInWorldSpace = positionInWorldSpace
    }

    func applyViewMatrix(_ viewMatrix: simd_float4x4) {
        positionInEyeSpace = viewMatrix * positionInWorldSpace
    }
}

/// What's needed to draw something in a frame.
@MainActor
struct RenderContext {
    let encoder: MTLRenderCommandEncoder
    let pipelines: Pipelines
    let viewMatrix: simd_float4x4
    let projectionMatrix: simd_float4x4
    let light: Light
    let pointSize: Float
}

@MainActor
protocol Renderable {
    func draw(_ context: RenderContext, modelMatrix: simd_float4x4)
}
