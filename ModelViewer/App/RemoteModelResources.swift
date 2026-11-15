//
//  RemoteModelResources.swift
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

/// Finds the files that a model refers to next to the model on the web, relative to the URL from
/// which it was downloaded (after any redirects).
final class RemoteModelResources: ModelResources, @unchecked Sendable {
    private let modelURL: URL
    private let session: URLSession
    private let lock = NSLock()
    private var missing: [String] = []

    /// File names that the model asked for, but which couldn't be found.
    var missingFiles: [String] {
        lock.withLock {
            var seen = Set<String>()
            return missing.filter { seen.insert($0).inserted }
        }
    }

    init(modelURL: URL, session: URLSession = .shared) {
        self.modelURL = modelURL
        self.session = session
    }

    /// Called by parsers on a background thread, so it's fine to wait for the download.
    func open(_ path: String) -> Data? {
        let normalized = ModelResourcePath.normalize(path)
        let fileName = ModelResourcePath.fileName(path)
        // Try the path relative to the model, and then just the file name, next to the model.
        var seen = Set<String>()
        for candidate in [normalized, fileName] where !candidate.isEmpty && seen.insert(candidate).inserted {
            let escaped = candidate.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? candidate
            guard let url = URL(string: escaped, relativeTo: modelURL)?.absoluteURL else {
                continue
            }
            if let data = Self.download(url, session: session) {
                return data
            }
        }
        lock.withLock { missing.append(fileName) }
        return nil
    }

    private static func download(_ url: URL, session: URLSession) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        let result = ResultBox()
        let task = session.dataTask(with: url) { data, response, _ in
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                result.data = data
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return result.data
    }

    private final class ResultBox: @unchecked Sendable {
        var data: Data?
    }
}
