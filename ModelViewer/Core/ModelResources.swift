//
//  ModelResources.swift
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

/// Provides the other files that a model refers to, such as an OBJ file's material libraries and textures.
protocol ModelResources: AnyObject {
    /// Reads the file with the given path, as written in the model (usually relative to the
    /// model's own location), or returns nil if the file isn't available.
    func open(_ path: String) -> Data?
}

enum ModelResourcePath {
    /// Returns just the file name of a path as written in a model file, which may use either kind of slash.
    static func fileName(_ path: String) -> String {
        let normalized = normalize(path)
        if let slash = normalized.lastIndex(of: "/") {
            return String(normalized[normalized.index(after: slash)...])
        }
        return normalized
    }

    /// Trims a path, removes surrounding quotes, and converts backslashes to slashes.
    static func normalize(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.count >= 2 && p.hasPrefix("\"") && p.hasSuffix("\"") {
            p = String(p.dropFirst().dropLast())
        }
        return p.replacingOccurrences(of: "\\", with: "/")
    }
}

/// Resources that are never available, for models that are loaded on their own.
final class NoModelResources: ModelResources {
    func open(_ path: String) -> Data? { nil }
}

/// Resources found in a directory on disk (relative to the model), and among a set of other files
/// that were opened along with the model (matched by file name). Used by tests and by models that
/// are opened from a location whose neighbors are accessible.
final class FileModelResources: ModelResources, @unchecked Sendable {
    private let directory: URL?
    /// Other selected files, keyed by their lowercase file names.
    private let selectedFiles: [String: URL]
    private let lock = NSLock()
    private var missing: [String] = []

    /// File names that the model asked for, but which couldn't be found.
    var missingFiles: [String] {
        lock.withLock {
            var seen = Set<String>()
            return missing.filter { seen.insert($0).inserted }
        }
    }

    init(directory: URL?, selectedFiles: [URL] = []) {
        self.directory = directory
        var files: [String: URL] = [:]
        for url in selectedFiles {
            files[url.lastPathComponent.lowercased()] = url
        }
        self.selectedFiles = files
    }

    func open(_ path: String) -> Data? {
        if let data = openFile(path) {
            return data
        }
        lock.withLock { missing.append(ModelResourcePath.fileName(path)) }
        return nil
    }

    private func openFile(_ path: String) -> Data? {
        let normalized = ModelResourcePath.normalize(path)
        let fileName = ModelResourcePath.fileName(path)
        if let url = selectedFiles[fileName.lowercased()] {
            return Self.read(url)
        }
        guard let directory else {
            return nil
        }
        // Try the path relative to the model, and then just the file name, next to the model.
        for candidate in [normalized, fileName] where !candidate.isEmpty {
            let url = directory.appendingPathComponent(candidate)
            if let data = Self.read(url) {
                return data
            }
        }
        return nil
    }

    static func read(_ url: URL) -> Data? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }
}
