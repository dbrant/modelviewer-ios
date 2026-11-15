//
//  VdbLoader.swift
//  ModelViewer
//
//  Loads an OpenVDB file as a translucent volume (for fog volumes), or as a surface (for level
//  sets, and for volumes that are too large to resample).
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

enum VdbLoader {
    static func load(data: Data) throws -> Model {
        // What's displayed is prepared from the grids before the model is created, so that the
        // voxel data can be released before then.
        let createModel = try prepare(VdbReader(data: data).read())
        return try createModel()
    }

    private static func prepare(_ grids: VdbReader.Grids) throws -> () throws -> Model {
        let grid = grids.surface
        if !grid.isLevelSet {
            // A volume that's too large to resample is shown as a surface instead.
            // The temperature is what glows, if there is one (as with Blender's materials for fire),
            // and otherwise flames.
            let glowGrid = grids.temperature ?? grids.flames
            let glowKind: VolumeTexture.Glow = grids.temperature != nil ? .thermal : .flame
            if let volume = VolumeTexture.build(grid: grid, colorGrid: grids.color, glowGrid: glowGrid, glowKind: glowKind,
                                                maxBytes: VolumeTexture.maxBytes) {
                let gridName = grid.name
                let colorGridName = grids.color?.name
                let glowGridName = volume.glow != .none ? glowGrid?.name : nil
                return { VdbVolumeModel(volume: volume, gridName: gridName, colorGridName: colorGridName, glowGridName: glowGridName) }
            }
        }
        let surface = VdbModel.extractSurface(grids)
        return { try VdbModel(surface: surface) }
    }
}
