//
//  Shaders.metal
//  ModelViewer
//
//  Ported from the OpenGL ES shaders of the Android app. The matrices follow OpenGL's conventions
//  (with clip space depth from -1 to 1), so that lighting is computed exactly as on Android, and
//  the depth of each vertex is converted to Metal's range (0 to 1) only for rasterization.
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

#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

/// Converts a position in OpenGL's clip space to Metal's, whose depth ranges from 0 to 1.
static inline float4 toMetalClip(float4 p) {
    return float4(p.x, p.y, (p.z + p.w) * 0.5, p.w);
}

// MARK: - Meshes without materials (a single color, lit by one light)

struct SingleLightOut {
    float4 position [[position]];
    float3 normal;
    float3 viewPosition;
};

vertex SingleLightOut singleLightVertex(uint vid [[vertex_id]],
                                        const device packed_float3 *positions [[buffer(BufferIndexPositions)]],
                                        const device packed_float3 *normals [[buffer(BufferIndexNormals)]],
                                        constant MeshUniforms &u [[buffer(BufferIndexUniforms)]]) {
    SingleLightOut out;
    float4 glPosition = u.mvp * float4(float3(positions[vid]), 1.0);
    out.normal = normalize((u.mvp * float4(float3(normals[vid]), 0.0)).xyz);
    out.viewPosition = glPosition.xyz / glPosition.w;
    out.position = toMetalClip(glPosition);
    return out;
}

fragment float4 singleLightFragment(SingleLightOut in [[stage_in]],
                                    constant MeshUniforms &u [[buffer(BufferIndexUniforms)]]) {
    const float specularExp = 16.0;
    float3 lightPosNorm = normalize(u.lightPosition.xyz);
    float3 cameraDir = normalize(-in.viewPosition);
    float3 halfDir = normalize(lightPosNorm + cameraDir);
    float specular = pow(max(dot(halfDir, in.normal), 0.0), specularExp);
    float diffuse = max(dot(lightPosNorm, in.normal), 0.0);
    return u.ambientColor * (1.0 - diffuse) + u.diffuseColor * (diffuse - specular) + u.specularColor * specular;
}

// MARK: - Meshes with materials, vertex colors, and textures

struct MaterialOut {
    float4 position [[position]];
    float3 normal;
    float3 viewPosition;
    float4 color;
    float2 texCoord;
};

vertex MaterialOut materialVertex(uint vid [[vertex_id]],
                                  const device packed_float3 *positions [[buffer(BufferIndexPositions)]],
                                  const device packed_float3 *normals [[buffer(BufferIndexNormals)]],
                                  const device float4 *colors [[buffer(BufferIndexColors)]],
                                  const device packed_float2 *texCoords [[buffer(BufferIndexTexCoords)]],
                                  constant MeshUniforms &u [[buffer(BufferIndexUniforms)]],
                                  constant MaterialUniforms &m [[buffer(BufferIndexMaterial)]]) {
    MaterialOut out;
    float4 glPosition = u.mvp * float4(float3(positions[vid]), 1.0);
    out.normal = normalize((u.mvp * float4(float3(normals[vid]), 0.0)).xyz);
    out.viewPosition = glPosition.xyz / glPosition.w;
    out.position = toMetalClip(glPosition);
    // Attributes that the mesh doesn't have get constant values instead.
    out.color = u.hasColors != 0 ? colors[vid] : float4(1.0);
    float2 texCoord = u.hasTexCoords != 0 ? float2(texCoords[vid]) : float2(0.0);
    // Texture coordinates have their origin at the bottom left, but textures are uploaded top row first.
    texCoord = texCoord * m.textureScale + m.textureOffset;
    out.texCoord = float2(texCoord.x, 1.0 - texCoord.y);
    return out;
}

fragment float4 materialFragment(MaterialOut in [[stage_in]],
                                 constant MeshUniforms &u [[buffer(BufferIndexUniforms)]],
                                 constant MaterialUniforms &m [[buffer(BufferIndexMaterial)]],
                                 texture2d<float> diffuseTexture [[texture(0)]],
                                 sampler textureSampler [[sampler(0)]]) {
    const float ambient = 0.3;
    float4 base = m.diffuseColor * in.color;
    if (m.useTexture != 0) {
        base *= diffuseTexture.sample(textureSampler, in.texCoord);
    }
    // Materials with an alpha mask are only shown where their alpha reaches the cutoff.
    if (base.a < m.alphaCutoff) {
        discard_fragment();
    }
    float3 color = base.rgb;
    // Lighting: 0 = none (constant color), 1 = diffuse only, 2 = diffuse and specular
    if (m.lighting > 0) {
        float3 normal = normalize(in.normal);
        float3 lightDir = normalize(u.lightPosition.xyz);
        float diffuse = max(dot(lightDir, normal), 0.0);
        color *= ambient + (1.0 - ambient) * diffuse;
        if (m.lighting > 1) {
            float3 halfDir = normalize(lightDir + normalize(-in.viewPosition));
            color += m.specularColor.rgb * pow(max(dot(halfDir, normal), 0.0), m.shininess);
        }
    }
    return float4(color + m.emissiveColor.rgb, mix(base.a, 1.0, m.opaque));
}

// MARK: - Point clouds

struct PointOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 color;
};

vertex PointOut pointVertex(uint vid [[vertex_id]],
                            const device packed_float3 *positions [[buffer(BufferIndexPositions)]],
                            const device float4 *colors [[buffer(BufferIndexColors)]],
                            constant MeshUniforms &u [[buffer(BufferIndexUniforms)]]) {
    PointOut out;
    out.position = toMetalClip(u.mvp * float4(float3(positions[vid]), 1.0));
    out.pointSize = u.pointSize;
    out.color = u.hasColors != 0 ? colors[vid] : u.diffuseColor;
    return out;
}

fragment float4 pointFragment(PointOut in [[stage_in]]) {
    return in.color;
}

// MARK: - Floor (adapted from the Cardboard SDK sample)

struct FloorOut {
    float4 position [[position]];
    float3 grid;
    /// The depth that OpenGL's gl_FragCoord.z / gl_FragCoord.w gives.
    float depth;
};

vertex FloorOut floorVertex(uint vid [[vertex_id]],
                            const device packed_float3 *positions [[buffer(BufferIndexPositions)]],
                            constant FloorUniforms &u [[buffer(BufferIndexUniforms)]]) {
    FloorOut out;
    float4 position = float4(float3(positions[vid]), 1.0);
    out.grid = (u.model * position).xyz;
    out.position = toMetalClip(u.mvp * position);
    out.depth = out.position.z;
    return out;
}

fragment float4 floorFragment(FloorOut in [[stage_in]],
                              constant FloorUniforms &u [[buffer(BufferIndexUniforms)]]) {
    float depth = in.depth;
    float4 lineColor = max(0.0, (u.maxDepth - depth) / u.maxDepth) * u.lineColor + min(1.0, depth / u.maxDepth) * u.floorColor;

    // Lines cover the start of each grid cell (as on Android), and are anti-aliased: each pixel is
    // covered by a line as much as the line overlaps its footprint on the floor.
    float2 grid = abs(in.grid.xz);
    float2 footprint = max(fwidth(in.grid.xz), float2(1e-5));
    float halfWidth = u.lineWidth * 0.5;
    float2 offset = fmod(grid, u.gridUnit) - halfWidth;
    float2 distance = min(abs(offset), u.gridUnit - abs(offset));
    float2 coverage = saturate((halfWidth - distance) / footprint + 0.5) * min(1.0, 2.0 * halfWidth / footprint);
    // Where the cells are smaller than pixels, the lines fade out, rather than shimmering.
    coverage *= saturate(u.gridUnit / (footprint * 3.0) - 0.5);
    return mix(u.floorColor, lineColor, max(coverage.x, coverage.y));
}

// MARK: - Volumes (ray marched through a 3D texture)

struct VolumeOut {
    float4 position [[position]];
    float3 texCoord;
};

vertex VolumeOut volumeVertex(uint vid [[vertex_id]],
                              const device packed_float3 *positions [[buffer(BufferIndexPositions)]],
                              constant VolumeUniforms &u [[buffer(BufferIndexUniforms)]]) {
    VolumeOut out;
    // The vertices of the volume's box are in texture coordinates.
    out.texCoord = float3(positions[vid]);
    out.position = toMetalClip(u.mvp * float4(out.texCoord, 1.0));
    return out;
}

fragment float4 volumeFragment(VolumeOut in [[stage_in]],
                               constant VolumeUniforms &u [[buffer(BufferIndexUniforms)]],
                               // Density of each texel (as a fraction of the density scale), the fraction of the
                               // light from above that reaches it, and how much it glows, if the volume does.
                               texture3d<float> volume [[texture(0)]],
                               // Color of each texel, premultiplied by its density.
                               texture3d<float> colorVolume [[texture(1)]],
                               // Color of the light that fire emits, for each amount of glow, at full brightness.
                               texture2d<float> fireRamp [[texture(2)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    const int MAX_STEPS = 4096;
    const float STEP_TEXELS = 1.0;
    // Once this little light gets through, the rest of the volume behind it can't be seen.
    const float MIN_TRANSMITTANCE = 0.01;
    const float AMBIENT_LIGHT = 0.15;
    const float TOP_LIGHT = 0.75;
    const float CAMERA_LIGHT = 0.35;
    const float3 LUMINANCE = float3(0.2126, 0.7152, 0.0722);

    // This fragment is on a back face of the volume's box, which is where the ray from the camera
    // leaves the box (at t = 1). The ray enters the box where it crosses the last of the near
    // planes of each axis, or at the camera, if it's inside the box.
    float3 cameraPos = u.cameraPosition.xyz;
    float3 dir = in.texCoord - cameraPos;
    float3 safeDir = select(dir, float3(1e-6), abs(dir) < float3(1e-6));
    float3 tNear = min(-cameraPos / safeDir, (1.0 - cameraPos) / safeDir);
    float t = max(max(tNear.x, tNear.y), max(tNear.z, 0.0));

    float dt = STEP_TEXELS / length(dir * u.textureSize.xyz);
    float stepLength = length(u.textureToWorld * dir) * dt;
    float stepDensity = u.densityScale * stepLength;
    // Start each ray at a random offset, which turns the banding of the steps into fine noise.
    t += dt * fract(sin(dot(in.position.xy, float2(12.9898, 78.233))) * 43758.5453);

    // Light that the volume reflects, and light that it emits by glowing.
    float3 reflected = float3(0.0);
    float3 emitted = float3(0.0);
    float transmittance = 1.0;
    for (int i = 0; i < MAX_STEPS && t < 1.0; i++) {
        float3 pos = cameraPos + dir * t;
        float3 voxel = volume.sample(s, pos, level(0)).rgb;
        float alpha = 0.0;
        if (voxel.r > 0.0) {
            alpha = 1.0 - exp(-voxel.r * stepDensity);
            float3 albedo = u.hasColor != 0 ? clamp(colorVolume.sample(s, pos, level(0)).rgb / voxel.r, 0.0, 1.0) : float3(u.albedo);
            // Light from above (attenuated by the volume above this point), from the camera
            // (attenuated by the volume in front of it), and ambient light.
            reflected += transmittance * alpha * albedo * (AMBIENT_LIGHT + TOP_LIGHT * voxel.g + CAMERA_LIGHT * transmittance);
        }
        if (voxel.b > 0.0) {
            // Hot parts of the volume glow as much as they absorb light (by Kirchhoff's law), and
            // flames glow on their own.
            float3 glow = fireRamp.sample(s, float2(voxel.b * (255.0 / 256.0) + 0.5 / 256.0, 0.5), level(0)).rgb
                * pow(voxel.b, u.glowExponent);
            emitted += transmittance * glow * (alpha * u.thermalGlow + stepLength * u.flameGlow);
        }
        transmittance *= 1.0 - alpha;
        if (transmittance < MIN_TRANSMITTANCE) {
            break;
        }
        t += dt;
    }

    // The light is computed in linear space, and converted to sRGB for display (with premultiplied
    // alpha). Reflected light covers what's behind the volume as much as the volume absorbs it,
    // but emitted light is added to it, so the light is converted according to how much of it is
    // emitted.
    float alpha = 1.0 - transmittance;
    float reflectedLuminance = dot(reflected, LUMINANCE);
    float emittedLuminance = dot(emitted, LUMINANCE);
    float coverage = mix(alpha, 1.0, emittedLuminance / max(reflectedLuminance + emittedLuminance, 1e-6));
    if (coverage < 1.0 / 255.0) {
        discard_fragment();
    }
    return float4(pow((reflected + emitted) / coverage, float3(1.0 / 2.2)) * coverage, alpha);
}
