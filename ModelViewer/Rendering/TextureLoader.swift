//
//  TextureLoader.swift
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
import Metal
import ImageIO
import CoreGraphics

/// Decodes images (PNG, JPEG, TGA, etc.) into Metal textures.
enum TextureLoader {
    struct Decoded {
        let texture: MTLTexture
        /// Whether any pixel of the image is less than fully opaque.
        let hasTransparency: Bool
    }

    /// Decodes an image into an RGBA texture with mipmaps, reduced to fit the maximum size. The colors
    /// of transparent pixels are kept intact (not premultiplied), for proper blending.
    static func load(device: MTLDevice, data: Data, maxSize: Int) throws -> Decoded {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw ModelError("Unsupported image format.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let pixelHeight = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let image: CGImage?
        if max(pixelWidth, pixelHeight) > maxSize {
            // Let ImageIO decode a reduced version directly, which saves memory.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSize,
                kCGImageSourceCreateThumbnailWithTransform: false,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image, image.width > 0, image.height > 0 else {
            throw ModelError("Unable to decode image.")
        }
        let (pixels, width, height, hasTransparency) = try rgbaPixels(of: image)
        let texture = try makeTexture(device: device, rgba: pixels, width: width, height: height, mipmapped: true)
        if texture.mipmapLevelCount > 1, let queue = device.makeCommandQueue(), let commandBuffer = queue.makeCommandBuffer(),
           let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commandBuffer.commit()
        }
        return Decoded(texture: texture, hasTransparency: hasTransparency)
    }

    /// Draws the image into RGBA pixels (without premultiplied alpha), in sRGB, with the top row first.
    private static func rgbaPixels(of image: CGImage) throws -> ([UInt8], Int, Int, Bool) {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.interpolationQuality = .high
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            throw ModelError("Unable to decode image.")
        }
        // Core Graphics only draws with premultiplied alpha, so undo it.
        var hasTransparency = false
        pixels.withUnsafeMutableBufferPointer { p in
            var i = 0
            let n = p.count
            while i < n {
                let a = p[i + 3]
                if a != 255 {
                    hasTransparency = true
                    if a != 0 {
                        let scale = 255 / Float(a)
                        p[i] = UInt8(min(Float(p[i]) * scale + 0.5, 255))
                        p[i + 1] = UInt8(min(Float(p[i + 1]) * scale + 0.5, 255))
                        p[i + 2] = UInt8(min(Float(p[i + 2]) * scale + 0.5, 255))
                    }
                }
                i += 4
            }
        }
        return (pixels, width, height, hasTransparency)
    }

    static func makeTexture(device: MTLDevice, rgba: [UInt8], width: Int, height: Int, mipmapped: Bool) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: mipmapped)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw ModelError("Unable to create texture.")
        }
        rgba.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: width * 4)
        }
        return texture
    }
}
