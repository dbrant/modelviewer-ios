//
//  make-icon.swift
//  Composes the app icon: the background of the Android adaptive icon (three blue polygons),
//  with a foreground image (the bunny, with a transparent background) centered over it.
//
//  The foreground is cropped to its opaque part, which is scaled so that its larger dimension is the
//  given fraction of the icon's size, and centered.
//
//  Usage: swift Tools/make-icon.swift <foreground.png> <output.png> [size] [fraction]
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let foregroundPath = args[1]
let outputPath = args[2]
let size = args.count > 3 ? Int(args[3])! : 1024
let fraction = args.count > 4 ? Double(args[4])! : 0.75

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
// The icon is opaque, as iOS requires.
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.interpolationQuality = .high
let s = Double(size) / 256

// Android vector coordinates have y down; Core Graphics has y up.
func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * s, y: Double(size) - y * s) }
func color(_ hex: UInt32) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255, 1])!
}
func polygon(_ start: (Double, Double), _ deltas: [(Double, Double)], _ fill: UInt32) {
    var x = start.0, y = start.1
    context.beginPath()
    context.move(to: point(x, y))
    for d in deltas {
        x += d.0; y += d.1
        context.addLine(to: point(x, y))
    }
    context.closePath()
    context.setFillColor(color(fill))
    context.fillPath()
}

// From ic_launcher_background.xml.
polygon((-2.5, -1.86), [(260.71, 0), (0, 261.43), (-260.71, 0)], 0x5493ff)
polygon((-12.6, 101.21), [(318.25, 50.21), (-25.29, 161.15), (-318.25, -50.21)], 0x3973ff)
polygon((279.89, -31.62), [(149.69, 144.16), (-149.68, 155.42), (-149.69, -144.16)], 0x4280ff)

let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: foregroundPath) as CFURL, nil)!
let foreground = CGImageSourceCreateImageAtIndex(source, 0, nil)!

// Find the bounds of the opaque part of the foreground.
let fw = foreground.width, fh = foreground.height
var alpha = [UInt8](repeating: 0, count: fw * fh)
alpha.withUnsafeMutableBytes { buffer in
    let c = CGContext(data: buffer.baseAddress, width: fw, height: fh, bitsPerComponent: 8, bytesPerRow: fw, space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!
    c.draw(foreground, in: CGRect(x: 0, y: 0, width: fw, height: fh))
}
var minX = fw, minY = fh, maxX = 0, maxY = 0
for y in 0..<fh {
    for x in 0..<fw where alpha[y * fw + x] > 8 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}
// Rows of the alpha bitmap start at the top.
let crop = foreground.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!
let scale = Double(size) * fraction / Double(max(crop.width, crop.height))
let w = Double(crop.width) * scale, h = Double(crop.height) * scale
context.draw(crop, in: CGRect(x: (Double(size) - w) / 2, y: (Double(size) - h) / 2, width: w, height: h))

let image = context.makeImage()!
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("Wrote \(outputPath)")
