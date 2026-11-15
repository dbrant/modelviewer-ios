//
//  GltfModel.swift
//  ModelViewer
//
//  Displays a glTF model (GLB, or .gltf with its buffers and images), with its materials, textures,
//  and vertex colors. Animations are ignored, so the model is shown in its default pose.
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

final class GltfModel: MeshModel, @unchecked Sendable {
    /// The Y axis is up, as in OBJ files.
    override var orientation: ModelOrientation { .yUp }

    /// Reads a GLB file (recognized by its "glTF" magic), or the JSON of a .gltf file.
    /// Separate buffers and images are opened from the given resources.
    init(data: Data, resources: ModelResources? = nil) throws {
        super.init()
        let mesh = try GltfReader(data: data, resources: resources).read()
        vertices = mesh.positions
        normals = mesh.normals
        texCoords = mesh.texCoords
        colors = mesh.colors
        indices = mesh.indices
        parts = mesh.parts
        computeBoundsFromVertices()
    }
}
