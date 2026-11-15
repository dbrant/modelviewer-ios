//
//  VdbReader.swift
//  ModelViewer
//
//  Reader for OpenVDB (.vdb) files. Reads the first scalar (float or double) grid in the file,
//  which is enough for visualizing level sets and fog volumes, and grids with the color, the
//  temperature, and the flames of the volume, if there are any.
//
//  Info on the format: https://www.openvdb.org/documentation/doxygen/ and the OpenVDB source code,
//  in particular io/Archive.cc, io/Compression.h, and the readTopology/readBuffers methods of
//  tree/RootNode.h, tree/InternalNode.h, and tree/LeafNode.h.
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

final class VdbReader {
    private static let magic: UInt64 = 0x56444220
    private static let minFileVersion = 222
    private static let halfFloatSuffix = "_HalfFloat"
    private static let maxStringLength = 0x100000
    private static let maxCompressedSize = 0x10000000
    private static let maxNodeCoord = 1 << 20

    /// Names of vector grids that hold the colors of a volume (lowercase).
    private static let colorGridNames: Set<String> = ["cd", "color", "colour", "albedo"]

    /// Name of a scalar grid that holds the temperature of a volume, such as fire (lowercase).
    private static let temperatureGridName = "temperature"

    /// Names of scalar grids that hold the intensity of flames, which glow on their own
    /// (lowercase): "flames" from EmberGen, and "flame" from Blender.
    private static let flameGridNames: Set<String> = ["flames", "flame"]

    private static let compressZip = 0x1
    private static let compressActiveMask = 0x2
    private static let compressBlosc = 0x4

    // Flags that describe how inactive values are stored, when using active mask compression.
    private static let noMaskOrInactiveVals = 0
    private static let noMaskAndMinusBg = 1
    private static let noMaskAndOneInactiveVal = 2
    private static let maskAndNoInactiveVals = 3
    private static let maskAndOneInactiveVal = 4
    private static let maskAndTwoInactiveVals = 5
    private static let noMaskAndAllVals = 6

    private var stream: BinaryReader

    private var compression = 0
    private var valueSize = 4
    private var components = 1
    private var isHalf = false
    private var background: [Float] = [0]
    private var byteBuffer = [UInt8](repeating: 0, count: 0x1000)
    private var compressedBuffer = [UInt8](repeating: 0, count: 0x1000)
    private let blosc = Blosc()

    /// The grids that were read from a file.
    struct Grids {
        let surface: VdbGrid
        let color: VdbGrid?
        let temperature: VdbGrid?
        let flames: VdbGrid?
    }

    init(data: Data) {
        stream = BinaryReader(data)
    }

    /// Reads the first scalar grid in the file.
    func readGrid() throws -> VdbGrid {
        try read().surface
    }

    /// Reads the first scalar grid in the file (other than a temperature or flame grid), a vector
    /// grid that holds the colors of the volume (with a name like "Cd" or "color"), and scalar grids
    /// with its temperature (named "temperature") and its flames (named "flames" or "flame"), if
    /// there are any.
    func read() throws -> Grids {
        if try stream.readUInt64LE() != Self.magic {
            throw ModelError("Not a valid OpenVDB file.")
        }
        let fileVersion = Int(try stream.readInt32LE())
        if fileVersion < Self.minFileVersion {
            throw ModelError("Unsupported OpenVDB file version: \(fileVersion)")
        }
        // library major and minor version
        _ = try stream.readInt32LE()
        _ = try stream.readInt32LE()
        let hasGridOffsets = try stream.readUInt8() != 0
        // UUID, stored as an ASCII string.
        try stream.skip(36)
        // File-level metadata, which we don't need.
        _ = try readMetadata()

        let gridCount = Int(try stream.readInt32LE())
        var skippedTypes: [String] = []
        var surface: VdbGrid?
        var color: VdbGrid?
        var temperature: VdbGrid?
        var flames: VdbGrid?
        for _ in 0..<max(gridCount, 0) {
            // The unique name may have a suffix that disambiguates grids with the same name.
            var name = try readString()
            if let separator = name.firstIndex(of: "\u{1e}") {
                name = String(name[..<separator])
            }
            var gridType = try readString()
            isHalf = gridType.hasSuffix(Self.halfFloatSuffix)
            if isHalf {
                gridType = String(gridType.dropLast(Self.halfFloatSuffix.count))
            }
            let instanceParent = try readString()
            let gridPos = Int(try stream.readInt64LE())
            _ = try stream.readInt64LE() // block position
            let endPos = Int(try stream.readInt64LE())

            let type = Self.parseGridType(gridType)
            let lowerName = name.lowercased()
            let isTemperatureName = lowerName == Self.temperatureGridName
            let isFlameName = Self.flameGridNames.contains(lowerName)
            let isSurface = surface == nil && type?.components == 1 && !isTemperatureName && !isFlameName
            let isColor = color == nil && type?.components == 3 && Self.colorGridNames.contains(lowerName)
            let isTemperature = temperature == nil && type?.components == 1 && isTemperatureName
            let isFlames = flames == nil && type?.components == 1 && isFlameName
            if let type, instanceParent.isEmpty, isSurface || isColor || isTemperature || isFlames {
                if hasGridOffsets {
                    try seek(gridPos)
                }
                valueSize = type.valueSize
                components = type.components
                let grid = try readGrid(name: name, log2Dims: type.log2Dims)
                if isSurface {
                    surface = grid
                } else if isColor {
                    color = grid
                } else if isTemperature {
                    temperature = grid
                } else {
                    flames = grid
                }
                if surface != nil && color != nil && temperature != nil && flames != nil {
                    break
                }
                if hasGridOffsets {
                    try seek(endPos)
                }
                continue
            }
            skippedTypes.append(gridType)
            if !hasGridOffsets {
                // Without offsets, there's no way to skip over this grid.
                break
            }
            try seek(endPos)
        }
        if surface == nil {
            // Without any other grid, the temperature or the flames are shown as the volume.
            if temperature != nil {
                surface = temperature
                temperature = nil
            } else {
                surface = flames
                flames = nil
            }
        }
        guard let surface else {
            throw ModelError("No supported grids found in file. Only float and double grids are supported" +
                             (skippedTypes.isEmpty ? "." : " (found: \(skippedTypes.joined(separator: ", ")))."))
        }
        return Grids(surface: surface, color: color, temperature: temperature, flames: flames)
    }

    private func readGrid(name: String, log2Dims: [Int]) throws -> VdbGrid {
        compression = Int(try stream.readInt32LE())
        let metadata = try readMetadata()
        let gridClass = metadata["class"] ?? ""
        let transform = try readTransform()

        // Number of buffers per leaf, which should always be 1.
        _ = try stream.readInt32LE()

        // Root node
        background = try readValues()
        let numTiles = Int(try stream.readInt32LE())
        let numChildren = Int(try stream.readInt32LE())
        if numTiles < 0 || numChildren < 0 {
            throw ModelError("Invalid root node.")
        }

        // Total log2 dimension of the nodes at each level, from the top internal level to the leaves.
        var totalLog2 = [Int](repeating: 0, count: log2Dims.count)
        for i in stride(from: log2Dims.count - 1, through: 0, by: -1) {
            totalLog2[i] = log2Dims[i] + (i < log2Dims.count - 1 ? totalLog2[i + 1] : 0)
        }
        let rootChildLog2 = totalLog2[0]

        var rootTiles: [Int64: [Float]] = [:]
        for _ in 0..<numTiles {
            let x = Int(try stream.readInt32LE())
            let y = Int(try stream.readInt32LE())
            let z = Int(try stream.readInt32LE())
            let value = try readValues()
            _ = try stream.readUInt8() // active state
            rootTiles[VdbGrid.packKey(x >> rootChildLog2, y >> rootChildLog2, z >> rootChildLog2)] = value
        }

        var internalNodes = [[Int64: [Float]]](repeating: [:], count: log2Dims.count - 1)
        var leafOrigins: [Int32] = []
        for _ in 0..<numChildren {
            let x = Int(try stream.readInt32LE())
            let y = Int(try stream.readInt32LE())
            let z = Int(try stream.readInt32LE())
            try readInternalTopology(0, x, y, z, log2Dims, totalLog2, &internalNodes, &leafOrigins)
        }

        // Now read the leaf buffers, which come in the same order as in the topology.
        let leafLog2 = log2Dims[log2Dims.count - 1]
        let leafSize = 1 << (3 * leafLog2)
        let numLeaves = leafOrigins.count / 3

        var leaves: [Int64: [Float]] = [:]
        leaves.reserveCapacity(numLeaves)
        var valueMask = [UInt64](repeating: 0, count: (leafSize + 63) / 64)
        var minValue = Float.greatestFiniteMagnitude
        var maxValue = -Float.greatestFiniteMagnitude
        for leaf in 0..<numLeaves {
            try readMask(&valueMask)
            var values = [Float](repeating: 0, count: leafSize * components)
            try readCompressedValues(&values, leafSize, valueMask)
            values.withUnsafeBufferPointer { p in
                for v in p {
                    if v < minValue { minValue = v }
                    if v > maxValue { maxValue = v }
                }
            }
            let x = Int(leafOrigins[leaf * 3])
            let y = Int(leafOrigins[leaf * 3 + 1])
            let z = Int(leafOrigins[leaf * 3 + 2])
            leaves[VdbGrid.packKey(x >> leafLog2, y >> leafLog2, z >> leafLog2)] = values
        }
        if numLeaves == 0 {
            minValue = background.min() ?? 0
            maxValue = background.max() ?? 0
        }

        let internalLevels = stride(from: log2Dims.count - 2, through: 0, by: -1).map {
            VdbGrid.InternalLevel(log2: log2Dims[$0], totalLog2: totalLog2[$0], nodes: internalNodes[$0])
        }
        return VdbGrid(name: name, gridClass: gridClass, components: components, backgroundValue: background,
                       transform: transform, leafLog2: leafLog2, internalLevels: internalLevels, rootTiles: rootTiles,
                       rootChildLog2: rootChildLog2, leaves: leaves, minValue: minValue, maxValue: maxValue)
    }

    private func readInternalTopology(_ level: Int, _ originX: Int, _ originY: Int, _ originZ: Int,
                                      _ log2Dims: [Int], _ totalLog2: [Int],
                                      _ internalNodes: inout [[Int64: [Float]]], _ leafOrigins: inout [Int32]) throws {
        let log2 = log2Dims[level]
        let numValues = 1 << (3 * log2)
        var childMask = [UInt64](repeating: 0, count: numValues / 64)
        var valueMask = [UInt64](repeating: 0, count: numValues / 64)
        try readMask(&childMask)
        try readMask(&valueMask)
        var values = [Float](repeating: 0, count: numValues * components)
        try readCompressedValues(&values, numValues, valueMask)
        let nodeLog2 = totalLog2[level]
        try checkCoordRange(originX >> nodeLog2, originY >> nodeLog2, originZ >> nodeLog2)
        internalNodes[level][VdbGrid.packKey(originX >> nodeLog2, originY >> nodeLog2, originZ >> nodeLog2)] = values

        let childLog2 = totalLog2[level + 1]
        let isLeafParent = level + 1 == log2Dims.count - 1
        let dimMask = (1 << log2) - 1
        let leafMaskBytes = (1 << (3 * log2Dims[log2Dims.count - 1])) / 8
        for i in 0..<numValues {
            if (childMask[i >> 6] >> UInt64(i & 63)) & 1 == 0 {
                continue
            }
            let x = originX + (((i >> (2 * log2)) & dimMask) << childLog2)
            let y = originY + (((i >> log2) & dimMask) << childLog2)
            let z = originZ + ((i & dimMask) << childLog2)
            if isLeafParent {
                // The leaf topology is just its value mask, which is repeated in the leaf buffers.
                try stream.skip(leafMaskBytes)
                try checkCoordRange(x >> childLog2, y >> childLog2, z >> childLog2)
                leafOrigins.append(Int32(truncatingIfNeeded: x))
                leafOrigins.append(Int32(truncatingIfNeeded: y))
                leafOrigins.append(Int32(truncatingIfNeeded: z))
            } else {
                try readInternalTopology(level + 1, x, y, z, log2Dims, totalLog2, &internalNodes, &leafOrigins)
            }
        }
    }

    private func checkCoordRange(_ x: Int, _ y: Int, _ z: Int) throws {
        let range = -Self.maxNodeCoord..<Self.maxNodeCoord
        if !range.contains(x) || !range.contains(y) || !range.contains(z) {
            throw ModelError("Grid extents are too large.")
        }
    }

    /// Reads a node's values (each with `components` floats), which may be compressed, and may omit
    /// inactive values that can be reconstructed from the value mask.
    /// See readCompressedValues() in OpenVDB's io/Compression.h
    private func readCompressedValues(_ dest: inout [Float], _ count: Int, _ valueMask: [UInt64]) throws {
        let maskCompressed = compression & Self.compressActiveMask != 0
        let metadata = Int(try stream.readUInt8())

        var inactiveVal0 = metadata == Self.noMaskOrInactiveVals ? background : background.map { -$0 }
        var inactiveVal1 = background
        if metadata == Self.noMaskAndOneInactiveVal || metadata == Self.maskAndOneInactiveVal ||
            metadata == Self.maskAndTwoInactiveVals {
            inactiveVal0 = try readValues()
            if metadata == Self.maskAndTwoInactiveVals {
                inactiveVal1 = try readValues()
            }
        }

        var selectionMask: [UInt64]?
        if metadata == Self.maskAndNoInactiveVals || metadata == Self.maskAndOneInactiveVal ||
            metadata == Self.maskAndTwoInactiveVals {
            var mask = [UInt64](repeating: 0, count: valueMask.count)
            try readMask(&mask)
            selectionMask = mask
        }

        if maskCompressed && metadata != Self.noMaskAndAllVals {
            // Only the active values are stored, so read them into the beginning of the
            // destination array, and then spread them out into their proper positions.
            var activeCount = 0
            for word in valueMask {
                activeCount += word.nonzeroBitCount
            }
            try readData(&dest, activeCount)
            // Going backward, an active value is never moved over one that hasn't been moved yet.
            let c = components
            var activeIndex = activeCount - 1
            dest.withUnsafeMutableBufferPointer { d in
                for i in stride(from: count - 1, through: 0, by: -1) {
                    let word = i >> 6
                    let bit = UInt64(1) << UInt64(i & 63)
                    if valueMask[word] & bit != 0 {
                        for k in 0..<c {
                            d[i * c + k] = d[activeIndex * c + k]
                        }
                        activeIndex -= 1
                    } else if let selectionMask, selectionMask[word] & bit != 0 {
                        for k in 0..<c {
                            d[i * c + k] = inactiveVal1[k]
                        }
                    } else {
                        for k in 0..<c {
                            d[i * c + k] = inactiveVal0[k]
                        }
                    }
                }
            }
        } else {
            try readData(&dest, count)
        }
    }

    /// Reads `count` values (each with `components` floats) into the destination array.
    private func readData(_ dest: inout [Float], _ count: Int) throws {
        if isHalf && count == 0 {
            // Empty arrays of half-float values are not written at all.
            return
        }
        let elementSize = isHalf ? 2 : valueSize
        let numFloats = count * components
        let numBytes = numFloats * elementSize
        if byteBuffer.count < numBytes {
            byteBuffer = [UInt8](repeating: 0, count: numBytes)
        }
        if compression & (Self.compressBlosc | Self.compressZip) != 0 {
            // A negative size means that the data is uncompressed.
            let size = Int(try stream.readInt64LE())
            if size <= 0 {
                if -size != numBytes {
                    throw ModelError("Unexpected uncompressed data size: \(-size), expected \(numBytes).")
                }
                try readBytes(into: &byteBuffer, numBytes)
            } else {
                if size > Self.maxCompressedSize {
                    throw ModelError("Invalid compressed data size: \(size)")
                }
                if compression & Self.compressBlosc != 0 {
                    if compressedBuffer.count < size {
                        compressedBuffer = [UInt8](repeating: 0, count: size)
                    }
                    try readBytes(into: &compressedBuffer, size)
                    try blosc.decompress(compressedBuffer, size, &byteBuffer, numBytes)
                } else {
                    let compressed = try stream.readData(size)
                    let inflated = try Inflater.inflate(compressed, zlibWrapped: true, expectedSize: numBytes)
                    if inflated.count != numBytes {
                        throw ModelError("Unexpected decompressed data size: \(inflated.count), expected \(numBytes).")
                    }
                    inflated.copyBytes(to: &byteBuffer, count: numBytes)
                }
            }
        } else {
            try readBytes(into: &byteBuffer, numBytes)
        }

        byteBuffer.withUnsafeBytes { raw in
            dest.withUnsafeMutableBufferPointer { d in
                if isHalf {
                    for i in 0..<numFloats {
                        d[i] = Self.halfToFloat(Int(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))))
                    }
                } else if valueSize == 8 {
                    for i in 0..<numFloats {
                        d[i] = Float(Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self))))
                    }
                } else {
                    for i in 0..<numFloats {
                        d[i] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
                    }
                }
            }
        }
    }

    /// Copies the next `count` bytes of the file into the beginning of the given buffer.
    private func readBytes(into buffer: inout [UInt8], _ count: Int) throws {
        let start = stream.position
        try stream.skip(count)
        if count > 0 {
            stream.data.copyBytes(to: &buffer, from: start..<(start + count))
        }
    }

    /// Reads a single value of the grid's type, which is never stored as half-float.
    private func readValues() throws -> [Float] {
        var values = [Float](repeating: 0, count: components)
        for i in 0..<components {
            values[i] = valueSize == 8 ? Float(try stream.readDoubleLE()) : try stream.readFloatLE()
        }
        return values
    }

    private struct GridType {
        let valueSize: Int
        let components: Int
        let log2Dims: [Int]
    }

    /// Parses a grid type such as "Tree_float_5_4_3", which means a float grid with internal nodes of
    /// log2 dimension 5 and 4, and leaf nodes of log2 dimension 3. Returns nil if the type isn't supported.
    private static func parseGridType(_ gridType: String) -> GridType? {
        let typeParts = gridType.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        if typeParts.count < 3 || typeParts[0] != "Tree" {
            return nil
        }
        let log2Dims = typeParts.dropFirst(2).compactMap { Int($0) }
        if log2Dims.count != typeParts.count - 2 || log2Dims.count < 2 || log2Dims.contains(where: { !(2...7).contains($0) }) {
            return nil
        }
        switch typeParts[1] {
        case "float": return GridType(valueSize: 4, components: 1, log2Dims: log2Dims)
        case "double": return GridType(valueSize: 8, components: 1, log2Dims: log2Dims)
        case "vec3s": return GridType(valueSize: 4, components: 3, log2Dims: log2Dims)
        case "vec3d": return GridType(valueSize: 8, components: 3, log2Dims: log2Dims)
        default: return nil
        }
    }

    private func readMask(_ mask: inout [UInt64]) throws {
        for i in 0..<mask.count {
            mask[i] = try stream.readUInt64LE()
        }
    }

    /// Reads a metadata map, and returns the values of any string entries.
    private func readMetadata() throws -> [String: String] {
        var strings: [String: String] = [:]
        let count = Int(try stream.readInt32LE())
        for _ in 0..<max(count, 0) {
            let name = try readString()
            let type = try readString()
            let size = Int(try stream.readInt32LE())
            if size < 0 {
                throw ModelError("Invalid metadata size.")
            }
            if type == "string" && size <= Self.maxStringLength {
                strings[name] = String(decoding: try stream.readData(size), as: UTF8.self)
            } else {
                try stream.skip(size)
            }
        }
        return strings
    }

    /// Reads the grid's index-to-world transform, and returns it as a 4x3 affine matrix (row-major,
    /// applied to row vectors), which is how OpenVDB itself stores matrices.
    private func readTransform() throws -> [Double] {
        var matrix: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]
        let type = try readString()
        switch type {
        case "UniformScaleMap", "ScaleMap":
            try readScale(&matrix)
            // Precomputed values that we don't need:
            // voxel size, inverse scale, inverse scale squared, inverse twice scale.
            try stream.skip(4 * 24)
        case "UniformScaleTranslateMap", "ScaleTranslateMap":
            matrix[9] = try stream.readDoubleLE()
            matrix[10] = try stream.readDoubleLE()
            matrix[11] = try stream.readDoubleLE()
            try readScale(&matrix)
            try stream.skip(4 * 24)
        case "TranslationMap":
            matrix[9] = try stream.readDoubleLE()
            matrix[10] = try stream.readDoubleLE()
            matrix[11] = try stream.readDoubleLE()
        case "AffineMap", "UnitaryMap":
            for row in 0..<4 {
                for col in 0..<4 {
                    let value = try stream.readDoubleLE()
                    if col < 3 {
                        matrix[row * 3 + col] = value
                    }
                }
            }
        default:
            throw ModelError("Unsupported grid transform: \(type)")
        }
        return matrix
    }

    private func readScale(_ matrix: inout [Double]) throws {
        matrix[0] = try stream.readDoubleLE()
        matrix[4] = try stream.readDoubleLE()
        matrix[8] = try stream.readDoubleLE()
    }

    private func readString() throws -> String {
        let length = Int(try stream.readInt32LE())
        if length < 0 || length > Self.maxStringLength {
            throw ModelError("Invalid string length: \(length)")
        }
        return String(decoding: try stream.readData(length), as: UTF8.self)
    }

    private func seek(_ newPosition: Int) throws {
        if newPosition < 0 || newPosition > stream.count {
            throw ModelError("Invalid grid offset.")
        }
        stream.position = newPosition
    }

    static func halfToFloat(_ half: Int) -> Float {
        let sign = UInt32(half & 0x8000) << 16
        let exponent = (half >> 10) & 0x1f
        let mantissa = UInt32(half & 0x3ff)
        switch exponent {
        case 0:
            // zero or subnormal
            let value = Float(mantissa) * (1 / Float(1 << 24))
            return sign != 0 ? -value : value
        case 0x1f:
            return Float(bitPattern: sign | 0x7f80_0000 | (mantissa << 13))
        default:
            return Float(bitPattern: sign | (UInt32(exponent + 112) << 23) | (mantissa << 13))
        }
    }
}
