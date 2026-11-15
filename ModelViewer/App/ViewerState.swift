//
//  ViewerState.swift
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

import Foundation
import Observation
import ImageIO
import UniformTypeIdentifiers
import os

/// The model that's shown, and the loading of new ones.
@MainActor
@Observable
final class ViewerState {
    private static let logger = Logger(subsystem: "com.dmitrybrant.modelviewer", category: "ViewerState")

    private(set) var model: Model?
    private(set) var isLoading = false
    /// Changes whenever the view of the model should be reset.
    private(set) var resetToken = 0

    var errorMessage: String?
    /// Files that the current model uses, but which weren't found.
    var missingFiles: [String] = []

    /// Gives access to the view of the model, for taking snapshots.
    let scene = SceneController()

    private var sampleIndex = 0
    private var loadTask: Task<Void, Never>?

    /// The sample models that are bundled with the app.
    let sampleURLs: [URL] = (Bundle.main.urls(forResourcesWithExtension: "stl", subdirectory: nil) ?? [])
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    var title: String { model?.title ?? String(localized: "3D Model Viewer") }

    func resetView() {
        resetToken += 1
    }

    /// Opens the first of the given files that looks like a model, and makes any other files
    /// available to it (e.g. the materials and textures of an OBJ model).
    func open(urls: [URL]) {
        guard !urls.isEmpty else {
            return
        }
        if let url = urls.first, url.scheme == "http" || url.scheme == "https" {
            openRemote(url)
            return
        }
        let modelIndex = urls.firstIndex { ModelLoader.isModelFile($0.lastPathComponent) } ?? 0
        let modelURL = urls[modelIndex]
        let others = urls.enumerated().filter { $0.offset != modelIndex }.map(\.element)
        load(fileName: modelURL.lastPathComponent) {
            let accessing = modelURL.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    modelURL.stopAccessingSecurityScopedResource()
                }
            }
            let data = try Self.readCoordinated(modelURL)
            // Files next to the model are only accessible if the model is in the app's own
            // documents (or the user picked them too).
            let resources = FileModelResources(directory: modelURL.deletingLastPathComponent(), selectedFiles: others)
            let model = try ModelLoader.load(data: data, fileName: modelURL.lastPathComponent, resources: resources)
            return (model, resources.missingFiles)
        }
    }

    /// Downloads a model from the web, along with any files that it refers to.
    func openRemote(_ url: URL) {
        let fileName = url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
        load(fileName: fileName) {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ModelError(String(localized: "The server responded with error \(http.statusCode)."))
            }
            // Files that the model refers to are relative to where it ended up (after any redirects).
            let finalURL = response.url ?? url
            let name = response.suggestedFilename.flatMap { ModelLoader.isModelFile($0) ? $0 : nil } ?? finalURL.lastPathComponent
            let resources = RemoteModelResources(modelURL: finalURL)
            let model = try ModelLoader.load(data: data, fileName: name, resources: resources)
            return (model, resources.missingFiles)
        }
    }

    /// Shows the next of the bundled sample models.
    func loadNextSample() {
        guard !sampleURLs.isEmpty else {
            return
        }
        let url = sampleURLs[sampleIndex % sampleURLs.count]
        sampleIndex += 1
        load(fileName: url.lastPathComponent) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return (try ModelLoader.load(data: data, fileName: url.lastPathComponent, resources: NoModelResources()), [])
        }
    }

    private func load(fileName: String, _ work: @escaping @Sendable () async throws -> (Model, [String])) {
        loadTask?.cancel()
        isLoading = true
        loadTask = Task {
            do {
                // Parsing happens off the main thread.
                let (model, missing) = try await Task.detached(priority: .userInitiated) {
                    try await work()
                }.value
                if Task.isCancelled {
                    return
                }
                self.model = model
                self.missingFiles = missing
                self.resetView()
                #if DEBUG
                renderIconIfRequested()
                #endif
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled {
                    return
                }
                Self.logger.error("Failed to load \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    #if DEBUG
    /// For making the app icon: with the launch argument `-RenderIcon <file name>`, writes an image of
    /// the model (with a transparent background) to the app's documents. With `-IconAngles "x,y;x,y;…"`,
    /// writes an image from each of the given view angles (in degrees), with the angles in the file names.
    private func renderIconIfRequested() {
        let defaults = UserDefaults.standard
        guard let name = defaults.string(forKey: "RenderIcon"), !name.isEmpty else {
            return
        }
        let angles: [(Float, Float)?] = defaults.string(forKey: "IconAngles").map { list in
            list.split(separator: ";").map { pair in
                let values = pair.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
                return values.count == 2 ? (values[0], values[1]) : nil
            }
        } ?? [nil]
        Task {
            try? await Task.sleep(for: .seconds(1))
            for angle in angles {
                var fileName = name
                if let angle {
                    scene.view?.renderer?.setRotation(x: angle.0, y: angle.1)
                    fileName = (name as NSString).deletingPathExtension + "_\(Int(angle.0))_\(Int(angle.1)).png"
                }
                guard let image = scene.transparentSnapshot(size: 2048) else {
                    continue
                }
                let url = URL.documentsDirectory.appending(path: fileName)
                if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, image, nil)
                    CGImageDestinationFinalize(destination)
                    Self.logger.info("Wrote icon to \(url.path, privacy: .public)")
                }
            }
        }
    }
    #endif

    /// Reads a file through a file coordinator, which downloads it first if it's in iCloud Drive or another file provider.
    nonisolated private static func readCoordinated(_ url: URL) throws -> Data {
        var coordinatorError: NSError?
        var result: Result<Data, Error> = .failure(ModelError("Unable to read the file."))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinatorError) { readURL in
            result = Result { try Data(contentsOf: readURL, options: .mappedIfSafe) }
        }
        if let coordinatorError {
            throw coordinatorError
        }
        return try result.get()
    }
}
