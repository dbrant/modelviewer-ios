//
//  ModelSceneView.swift
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

import SwiftUI
import MetalKit

/// Shows a model in 3D. Drag with one finger to rotate it, pinch to zoom, drag with two fingers to
/// move it, and double-tap to reset the view.
struct ModelSceneView: UIViewRepresentable {
    let model: Model?
    /// Changes whenever the view should be reset.
    let resetToken: Int
    /// Gives access to the view, for taking snapshots.
    let controller: SceneController

    func makeUIView(context: Context) -> ModelMTKView {
        let view = ModelMTKView()
        view.setModel(model)
        controller.view = view
        context.coordinator.resetToken = resetToken
        return view
    }

    func updateUIView(_ view: ModelMTKView, context: Context) {
        if view.renderer?.model !== model {
            view.setModel(model)
        } else if context.coordinator.resetToken != resetToken {
            view.resetView()
        }
        context.coordinator.resetToken = resetToken
        controller.view = view
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var resetToken = 0
    }
}

/// Gives SwiftUI access to the scene that's shown, to take snapshots of it.
@MainActor
final class SceneController {
    fileprivate(set) weak var view: ModelMTKView?

    /// An image of the current view, at the screen's resolution.
    func snapshot(showFloor: Bool = true) -> UIImage? {
        guard let view, let renderer = view.renderer else {
            return nil
        }
        let scale = view.contentScaleFactor
        let size = view.bounds.size
        guard let image = renderer.snapshot(width: Int(size.width * scale), height: Int(size.height * scale),
                                            contentScale: Float(scale), showFloor: showFloor) else {
            return nil
        }
        return UIImage(cgImage: image, scale: scale, orientation: .up)
    }

    /// An image of the model alone, with a transparent background, as a square of the given size in pixels.
    /// The transparency is found by rendering the model over black and over white.
    func transparentSnapshot(size: Int) -> CGImage? {
        guard let renderer = view?.renderer,
              let black = renderer.snapshot(width: size, height: size, contentScale: 1, clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1), showFloor: false),
              let white = renderer.snapshot(width: size, height: size, contentScale: 1, clearColor: MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1), showFloor: false) else {
            return nil
        }
        func pixels(_ image: CGImage) -> [UInt8] {
            var p = [UInt8](repeating: 0, count: size * size * 4)
            p.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            }
            return p
        }
        let b = pixels(black)
        let w = pixels(white)
        var result = [UInt8](repeating: 0, count: size * size * 4)
        for i in stride(from: 0, to: result.count, by: 4) {
            // Over black, the color is c·a; over white, it's c·a + (1 - a).
            let alpha = 255 - min(max(Int(w[i + 1]) - Int(b[i + 1]), 0), 255)
            result[i] = b[i]
            result[i + 1] = b[i + 1]
            result[i + 2] = b[i + 2]
            result[i + 3] = UInt8(alpha)
        }
        guard let provider = CGDataProvider(data: Data(result) as CFData) else {
            return nil
        }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// A Metal view that draws a model, and moves the camera around it with gestures.
final class ModelMTKView: MTKView, UIGestureRecognizerDelegate {
    private(set) var renderer: Renderer?
    private var lastPanLocation = CGPoint.zero
    private var lastTwoFingerLocation = CGPoint.zero

    init() {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        colorPixelFormat = Renderer.colorPixelFormat
        depthStencilPixelFormat = Renderer.depthPixelFormat
        sampleCount = Renderer.sampleCount
        clearColor = Renderer.clearColor
        // Frames are drawn only when something changes.
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "3D model")
        accessibilityHint = String(localized: "Drag to rotate, pinch to zoom, and drag with two fingers to move. Double-tap to reset the view.")
        accessibilityTraits = .allowsDirectInteraction

        if let device, let renderer = Renderer(device: device) {
            self.renderer = renderer
            delegate = renderer
        }
        setUpGestures()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setModel(_ model: Model?) {
        renderer?.setModel(model)
        accessibilityValue = model?.title
        setNeedsDisplay()
    }

    func resetView() {
        renderer?.resetView()
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    // MARK: - Gestures

    private func setUpGestures() {
        let rotate = UIPanGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
        rotate.maximumNumberOfTouches = 1
        rotate.allowedScrollTypesMask = []
        rotate.delegate = self
        addGestureRecognizer(rotate)

        let move = UIPanGestureRecognizer(target: self, action: #selector(handleMove(_:)))
        move.minimumNumberOfTouches = 2
        move.maximumNumberOfTouches = 2
        // Scrolling with a trackpad or mouse wheel moves the model too.
        move.allowedScrollTypesMask = .continuous
        move.delegate = self
        addGestureRecognizer(move)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @objc private func handleRotate(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            lastPanLocation = location
        case .changed:
            renderer?.rotate(dx: Float(location.x - lastPanLocation.x), dy: Float(location.y - lastPanLocation.y))
            lastPanLocation = location
            setNeedsDisplay()
        default:
            break
        }
    }

    @objc private func handleMove(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            lastTwoFingerLocation = location
        case .changed:
            // When a finger is lifted or added, the center of the touches jumps, which isn't a move.
            if gesture.numberOfTouches == 2 || gesture.numberOfTouches == 0 {
                renderer?.translate(dx: Float(location.x - lastTwoFingerLocation.x),
                                    dy: Float(location.y - lastTwoFingerLocation.y), zoom: 1)
                setNeedsDisplay()
            }
            lastTwoFingerLocation = location
        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed else {
            return
        }
        renderer?.translate(dx: 0, dy: 0, zoom: Float(gesture.scale))
        gesture.scale = 1
        setNeedsDisplay()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        resetView()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Pinching and moving with two fingers happen together.
        !(gestureRecognizer is UIPanGestureRecognizer && (gestureRecognizer as? UIPanGestureRecognizer)?.maximumNumberOfTouches == 1)
    }
}
