//
//  Material.swift
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

/// Surface properties of part of a mesh. Materials are compared by identity.
final class Material: @unchecked Sendable {
    let name: String

    var diffuseColor = SIMD3<Float>(0.8, 0.8, 0.8)
    var specularColor = SIMD3<Float>(0, 0, 0)
    var emissiveColor = SIMD3<Float>(0, 0, 0)
    var shininess: Float = 1
    var opacity: Float = 1

    /// How the material is lit.
    var lighting = Lighting.specular

    /// Encoded image (e.g. PNG or JPEG) to use as the diffuse texture, which is multiplied by the diffuse color.
    var diffuseTexture: Data?
    var diffuseTextureName: String?

    /// Scale and offset that are applied to texture coordinates.
    var textureScale = SIMD2<Float>(1, 1)
    var textureOffset = SIMD2<Float>(0, 0)

    /// How the alpha of the diffuse color (the opacity, times the alpha of the texture) is used.
    var alphaMode = AlphaMode.auto

    /// With `AlphaMode.mask`, the alpha at or above which the material is shown.
    var alphaCutoff: Float = 0.5

    init(name: String = "") {
        self.name = name
    }

    enum Lighting: Int, Sendable {
        /// Not lit at all (constant color).
        case none = 0
        /// Diffuse lighting only.
        case diffuse = 1
        /// Diffuse and specular lighting.
        case specular = 2
    }

    enum AlphaMode: Sendable {
        /// The material is blended if it's partly transparent (in its opacity or its texture).
        case auto
        /// The material is opaque, whatever its alpha.
        case opaque
        /// The material is shown (opaquely) only where its alpha is at least the `alphaCutoff`.
        case mask
        /// The material is blended.
        case blend
    }

    /// Material for models whose colors come only from their vertex colors.
    static func forVertexColors() -> Material {
        let material = Material()
        material.diffuseColor = SIMD3(1, 1, 1)
        material.specularColor = SIMD3(0.2, 0.2, 0.2)
        material.shininess = 20
        return material
    }
}

extension Material: Hashable {
    static func == (lhs: Material, rhs: Material) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
