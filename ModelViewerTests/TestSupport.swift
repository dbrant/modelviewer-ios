//
//  TestSupport.swift
//  ModelViewerTests
//

import Foundation
@testable import ModelViewer

private final class BundleToken {}

/// Access to the files in ModelViewerTests/Resources, which are copied into the test bundle.
enum TestResources {
    static func url(_ fileName: String) throws -> URL {
        let bundle = Bundle(for: BundleToken.self)
        let name = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw ModelError("Missing test resource: \(fileName)")
        }
        return url
    }

    static func data(_ fileName: String) throws -> Data {
        try Data(contentsOf: try url(fileName))
    }
}

/// Resources for tests, given as a map of file names (or paths) to their contents.
final class MapModelResources: ModelResources {
    private let files: [String: Data]
    private(set) var requested: [String] = []

    init(_ files: [String: Data]) {
        self.files = files
    }

    func open(_ path: String) -> Data? {
        requested.append(path)
        return files[path] ?? files[ModelResourcePath.fileName(path)]
    }
}
