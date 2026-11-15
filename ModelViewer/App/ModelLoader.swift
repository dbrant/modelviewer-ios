//
//  ModelLoader.swift
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

/// The kinds of models that can be opened.
enum ModelFormat: String, CaseIterable, Sendable {
    case stl, obj, ply, vdb, threeMF = "3mf", fbx, glb, gltf

    var fileExtension: String { rawValue }

    init?(fileName: String) {
        let ext = (fileName as NSString).pathExtension.lowercased()
        self.init(rawValue: ext)
    }

    /// Guesses the format of a file from its contents, for files whose names don't say.
    init(sniffing data: Data) {
        let head = data.prefix(64)
        func starts(with text: String) -> Bool {
            head.starts(with: Array(text.utf8))
        }
        if starts(with: "glTF") {
            self = .glb
        } else if starts(with: "PK\u{03}\u{04}") {
            self = .threeMF
        } else if starts(with: "Kaydara FBX Binary") || String(decoding: head, as: UTF8.self).contains("FBXHeaderExtension") {
            self = .fbx
        } else if starts(with: "ply") {
            self = .ply
        } else if head.count >= 4 && head.prefix(4).elementsEqual([0x20, 0x42, 0x44, 0x56]) {
            self = .vdb
        } else if let text = String(data: head, encoding: .utf8), text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
                  String(decoding: data.prefix(4096), as: UTF8.self).contains("\"asset\"") {
            self = .gltf
        } else {
            self = .stl
        }
    }
}

/// Creates models from the contents of their files.
enum ModelLoader {
    static var supportedExtensions: [String] { ModelFormat.allCases.map(\.fileExtension) }

    static func isModelFile(_ fileName: String) -> Bool {
        ModelFormat(fileName: fileName) != nil
    }

    /// Reads a model, whose format is determined by its file name (or else by its contents).
    /// Any other files that it refers to are found through the resources.
    static func load(data: Data, fileName: String, resources: ModelResources) throws -> Model {
        let format = ModelFormat(fileName: fileName) ?? ModelFormat(sniffing: data)
        let model: Model = switch format {
        case .stl: try StlModel(data: data)
        case .obj: try ObjModel(data: data, resources: resources)
        case .ply: try PlyModel(data: data)
        case .vdb: try VdbLoader.load(data: data)
        case .threeMF: try ThreeMfModel(data: data)
        case .fbx: try FbxModel(data: data, resources: resources)
        case .glb, .gltf: try GltfModel(data: data, resources: resources)
        }
        model.title = fileName
        return model
    }
}
