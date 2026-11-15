//
//  ShaderTypes.h
//  ModelViewer
//
//  Types shared between the Metal shaders and Swift (via the bridging header).
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

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

#ifdef __METAL_VERSION__
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
#else
#import <Foundation/Foundation.h>
#endif

typedef NS_ENUM(int, BufferIndex) {
    BufferIndexPositions = 0,
    BufferIndexNormals = 1,
    BufferIndexColors = 2,
    BufferIndexTexCoords = 3,
    BufferIndexUniforms = 4,
    BufferIndexMaterial = 5,
};

typedef struct {
    matrix_float4x4 mvp;
    /// Position of the light, in eye space.
    vector_float4 lightPosition;
    vector_float4 ambientColor;
    vector_float4 diffuseColor;
    vector_float4 specularColor;
    int hasColors;
    int hasTexCoords;
    float pointSize;
} MeshUniforms;

typedef struct {
    vector_float4 diffuseColor;
    vector_float4 specularColor;
    vector_float4 emissiveColor;
    vector_float2 textureScale;
    vector_float2 textureOffset;
    float shininess;
    int lighting;
    int useTexture;
    float alphaCutoff;
    float opaque;
} MaterialUniforms;

typedef struct {
    matrix_float4x4 model;
    matrix_float4x4 mvp;
    vector_float4 floorColor;
    vector_float4 lineColor;
    float maxDepth;
    float gridUnit;
    float lineWidth;
} FloorUniforms;

typedef struct {
    matrix_float4x4 mvp;
    /// Position of the camera, in texture coordinates.
    vector_float4 cameraPosition;
    vector_float4 textureSize;
    /// Transform of texture coordinates to world units, for measuring the distance that light travels.
    matrix_float3x3 textureToWorld;
    /// Extinction coefficient (per world unit) of the highest density.
    float densityScale;
    int hasColor;
    /// Fraction of the light that the volume reflects, when it has no colors.
    float albedo;
    /// Brightness of the glow increases with this power of the amount of glow.
    float glowExponent;
    /// Brightness of the glow from temperature, relative to how much light the volume absorbs.
    float thermalGlow;
    /// Brightness of the glow from flames, per world unit.
    float flameGlow;
} VolumeUniforms;

#endif /* ShaderTypes_h */
