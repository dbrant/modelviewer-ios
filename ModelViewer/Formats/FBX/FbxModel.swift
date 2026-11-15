//
//  FbxModel.swift
//  ModelViewer
//
//  Displays an FBX model (binary, or ASCII): the meshes of its scene, with their materials and
//  textures. Textures may be embedded in the file, or in separate files, which are opened from the
//  given resources. Animations are ignored, so the models are shown in the pose that's in the file.
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

final class FbxModel: MeshModel, @unchecked Sendable {
    /// The scene is converted to have the Y axis up, as in OBJ files.
    override var orientation: ModelOrientation { .yUp }

    init(data: Data, resources: ModelResources?) throws {
        super.init()
        let document = try FbxParser.parse(data)
        let mesh = try FbxScene(document: document, resources: resources).build()
        vertices = mesh.positions
        normals = mesh.normals
        texCoords = mesh.texCoords
        parts = mesh.parts.map { MeshPart(material: $0.material, first: $0.firstTriangle * 3, count: $0.triangleCount * 3) }
        computeBoundsFromVertices()
    }
}
