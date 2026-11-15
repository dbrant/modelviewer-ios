//
//  VdbTestWriter.swift
//  ModelViewerTests
//
//  Writes small OpenVDB files for testing, following the layout produced by OpenVDB itself
//  (see io/Archive.cc and writeCompressedValues() in io/Compression.h), with trees of the
//  standard 5_4_3 configuration. Supports Blosc (LZ4 with byte shuffling), zlib, and uncompressed
//  data, active mask compression, half-float values, double-precision grids, and vector grids.
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
import Compression

enum VdbTestWriter {
    static let compressNone = 0
    static let compressZip = 0x1
    static let compressActiveMask = 0x2
    static let compressBlosc = 0x4

    private static let leafLog2 = 3
    private static let lowerLog2 = 4
    private static let upperLog2 = 5
    static let leafSize = 1 << (3 * leafLog2)
    private static let lowerTotal = leafLog2 + lowerLog2
    private static let upperTotal = lowerTotal + upperLog2

    /// Integer coordinates, ordered by x, then y, then z.
    struct Coord: Hashable, Comparable {
        let x: Int
        let y: Int
        let z: Int

        init(_ x: Int, _ y: Int, _ z: Int) {
            self.x = x
            self.y = y
            self.z = z
        }

        static func < (a: Coord, b: Coord) -> Bool {
            (a.x, a.y, a.z) < (b.x, b.y, b.z)
        }
    }

    struct TileFunction {
        /// Value of a tile with the given origin and log2 size, for regions that have no leaves (in every component).
        let value: (_ x: Int, _ y: Int, _ z: Int, _ log2Size: Int) -> Float
        let active: (_ x: Int, _ y: Int, _ z: Int, _ log2Size: Int) -> Bool
    }

    final class Leaf {
        /// Values of each voxel, with the grid's number of components for each one.
        var values: [Float]
        var active = [Bool](repeating: false, count: VdbTestWriter.leafSize)

        init(components: Int = 1) {
            values = [Float](repeating: 0, count: VdbTestWriter.leafSize * components)
        }
    }

    final class Grid {
        var name = "grid"
        /// "float", "double", "vec3s", or "vec3d"
        var valueType = "float"
        var gridClass: String?
        var half = false
        var compression = VdbTestWriter.compressBlosc | VdbTestWriter.compressActiveMask
        var bloscSplit = true
        /// The background value (in every component)
        var background: Float = 0
        var scale: [Double] = [1, 1, 1]
        var translation: [Double] = [0, 0, 0]
        /// Leaves keyed by origin; iteration order doesn't matter.
        var leaves: [Coord: Leaf] = [:]
        var tiles: TileFunction?
        /// Root-level tiles: origin (multiple of 4096) and value (in every component), written as active.
        var rootTiles: [(Coord, Float)] = []
        /// If set, this grid is written with the given type name and opaque contents instead.
        var rawType: String?
        var rawPayload: [UInt8]?
    }

    static func write(_ grids: [Grid]) -> Data {
        var out = Out()
        out.int64(0x56444220)
        out.int32(224) // file version
        out.int32(12) // library major version
        out.int32(1) // library minor version
        out.int8(1) // has grid offsets
        out.bytes(Array("0EA4B2C5-0F55-4B24-9C25-5CFD16E1E1CE".utf8))
        out.int32(1) // file metadata
        writeStringMeta(&out, "creator", "ModelViewer tests")
        out.int32(grids.count)
        for grid in grids {
            let parts: ([UInt8], [UInt8]) = grid.rawPayload.map { ($0, []) } ?? writeGrid(grid)
            let type = grid.rawType ?? ("Tree_" + grid.valueType + "_5_4_3" + (grid.half ? "_HalfFloat" : ""))
            out.string(grid.name)
            out.string(type)
            out.string("") // instance parent
            let gridPos = out.bytes.count + 24
            out.int64(gridPos)
            out.int64(gridPos + parts.0.count)
            out.int64(gridPos + parts.0.count + parts.1.count)
            out.bytes(parts.0)
            out.bytes(parts.1)
        }
        return Data(out.bytes)
    }

    /// Returns the grid's header and topology, and its leaf buffers, as two separate arrays.
    private static func writeGrid(_ grid: Grid) -> ([UInt8], [UInt8]) {
        let valueSize = grid.valueType == "double" || grid.valueType == "vec3d" ? 8 : 4
        let components = grid.valueType.hasPrefix("vec3") ? 3 : 1
        var out = Out()
        out.int32(grid.compression)

        out.int32(grid.gridClass != nil ? 2 : 1)
        if let gridClass = grid.gridClass {
            writeStringMeta(&out, "class", gridClass)
        }
        // Metadata of an unknown type, which should be skipped.
        out.string("file_delayed_load")
        out.string("__delayedload")
        out.int32(5)
        out.bytes([1, 2, 3, 4, 5])

        let s = grid.scale
        out.string("ScaleTranslateMap")
        out.vec3d(grid.translation)
        out.vec3d(s)
        out.vec3d(s) // voxel size
        out.vec3d([1 / s[0], 1 / s[1], 1 / s[2]])
        out.vec3d([1 / (s[0] * s[0]), 1 / (s[1] * s[1]), 1 / (s[2] * s[2])])
        out.vec3d([0.5 / s[0], 0.5 / s[1], 0.5 / s[2]])

        out.int32(1) // buffer count
        out.values(filled(grid.background, components), valueSize)

        // Group the leaves by their upper and lower internal nodes, in the order that OpenVDB writes them.
        var tree: [Coord: [Coord: [Coord: Leaf]]] = [:]
        for (o, leaf) in grid.leaves {
            let upper = Coord(floor(o.x, upperTotal), floor(o.y, upperTotal), floor(o.z, upperTotal))
            let lower = Coord(floor(o.x, lowerTotal), floor(o.y, lowerTotal), floor(o.z, lowerTotal))
            tree[upper, default: [:]][lower, default: [:]][o] = leaf
        }

        out.int32(grid.rootTiles.count)
        out.int32(tree.count)
        for (origin, value) in grid.rootTiles {
            out.coord(origin)
            out.values(filled(value, components), valueSize)
            out.int8(1)
        }
        var leafOrder: [Leaf] = []
        for upper in tree.keys.sorted() {
            let lowers = tree[upper]!
            out.coord(upper)
            writeInternalNode(&out, grid, valueSize, components, upper, upperLog2, lowerTotal, Set(lowers.keys)) { lowerOrigin, out in
                let leaves = lowers[lowerOrigin]!
                writeInternalNode(&out, grid, valueSize, components, lowerOrigin, lowerLog2, leafLog2, Set(leaves.keys)) { leafOrigin, out in
                    let leaf = leaves[leafOrigin]!
                    out.mask(leaf.active)
                    leafOrder.append(leaf)
                }
            }
        }

        var buffers = Out()
        for leaf in leafOrder {
            buffers.mask(leaf.active)
            writeCompressedValues(&buffers, grid, valueSize, components, leaf.values, leaf.active,
                                  [Bool](repeating: false, count: leafSize))
        }
        return (out.bytes, buffers.bytes)
    }

    private static func writeInternalNode(_ out: inout Out, _ grid: Grid, _ valueSize: Int, _ components: Int, _ origin: Coord,
                                          _ log2: Int, _ childLog2: Int, _ children: Set<Coord>,
                                          _ childWriter: (Coord, inout Out) -> Void) {
        let numValues = 1 << (3 * log2)
        let dim = 1 << log2
        var childMask = [Bool](repeating: false, count: numValues)
        var valueMask = [Bool](repeating: false, count: numValues)
        var values = [Float](repeating: 0, count: numValues * components)
        var childOrigins: [Coord] = []
        for i in 0..<numValues {
            let x = origin.x + (((i >> (2 * log2)) & (dim - 1)) << childLog2)
            let y = origin.y + (((i >> log2) & (dim - 1)) << childLog2)
            let z = origin.z + ((i & (dim - 1)) << childLog2)
            let childOrigin = Coord(x, y, z)
            if children.contains(childOrigin) {
                childMask[i] = true
                childOrigins.append(childOrigin)
            } else {
                let value = grid.tiles!.value(x, y, z, childLog2)
                for c in 0..<components {
                    values[i * components + c] = value
                }
                valueMask[i] = grid.tiles!.active(x, y, z, childLog2)
            }
        }
        out.mask(childMask)
        out.mask(valueMask)
        writeCompressedValues(&out, grid, valueSize, components, values, valueMask, childMask)
        for childOrigin in childOrigins {
            childWriter(childOrigin, &out)
        }
    }

    /// Whether two values are the same, bit for bit (as with Java's Float.equals).
    private static func same(_ a: [Float], _ b: [Float]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern }
    }

    /// See writeCompressedValues() in OpenVDB's io/Compression.h
    private static func writeCompressedValues(_ out: inout Out, _ grid: Grid, _ valueSize: Int, _ components: Int, _ values: [Float],
                                              _ valueMask: [Bool], _ childMask: [Bool]) {
        if grid.compression & compressActiveMask == 0 {
            out.int8(6) // NO_MASK_AND_ALL_VALS
            writeData(&out, grid, valueSize, values)
            return
        }
        let count = valueMask.count
        let bg = filled(grid.background, components)
        let minusBg = filled(-grid.background, components)
        func value(_ i: Int) -> [Float] {
            Array(values[(i * components)..<((i + 1) * components)])
        }
        var inactiveValues: [[Float]] = []
        for i in 0..<count where !valueMask[i] && !childMask[i] {
            let v = value(i)
            if !inactiveValues.contains(where: { same($0, v) }) {
                inactiveValues.append(v)
            }
        }
        var metadata: Int
        var inactive0: [Float]?
        var inactive1: [Float]?
        if inactiveValues.isEmpty {
            metadata = 0
        } else if inactiveValues.count == 1 {
            inactive0 = inactiveValues[0]
            metadata = same(inactive0!, bg) ? 0 : same(inactive0!, minusBg) ? 1 : 2
        } else if inactiveValues.count == 2 {
            if inactiveValues.contains(where: { same($0, bg) }) {
                inactive1 = bg
                inactive0 = same(inactiveValues[0], bg) ? inactiveValues[1] : inactiveValues[0]
                metadata = same(inactive0!, minusBg) ? 3 : 4
            } else {
                inactive0 = inactiveValues[0]
                inactive1 = inactiveValues[1]
                metadata = 5
            }
        } else {
            metadata = 6
        }
        out.int8(metadata)
        if metadata == 6 {
            writeData(&out, grid, valueSize, values)
            return
        }
        if metadata == 2 || metadata == 4 || metadata == 5 {
            out.values(inactive0!, valueSize)
        }
        if metadata == 5 {
            out.values(inactive1!, valueSize)
        }
        if metadata >= 3 {
            var selection = [Bool](repeating: false, count: count)
            for i in 0..<count {
                selection[i] = !valueMask[i] && !childMask[i] && inactive1.map { same(value(i), $0) } == true
            }
            out.mask(selection)
        }
        var activeValues: [Float] = []
        for i in 0..<count where valueMask[i] {
            activeValues.append(contentsOf: value(i))
        }
        writeData(&out, grid, valueSize, activeValues)
    }

    private static func filled(_ value: Float, _ components: Int) -> [Float] {
        [Float](repeating: value, count: components)
    }

    private static func writeData(_ out: inout Out, _ grid: Grid, _ valueSize: Int, _ values: [Float]) {
        if grid.half && values.isEmpty {
            // OpenVDB writes nothing at all for empty half-float arrays.
            return
        }
        var buffer = Out()
        for v in values {
            if grid.half {
                buffer.int16(Int(floatToHalf(v)))
            } else if valueSize == 8 {
                buffer.int64(Int(Int64(bitPattern: Double(v).bitPattern)))
            } else {
                buffer.int32(Int(Int32(bitPattern: v.bitPattern)))
            }
        }
        let data = buffer.bytes
        if grid.compression & compressBlosc != 0 {
            let compressed = data.isEmpty ? nil : bloscCompress(data, 4, grid.bloscSplit)
            writeSizedData(&out, data, compressed)
        } else if grid.compression & compressZip != 0 {
            let compressed = zlibCompress(data)
            writeSizedData(&out, data, compressed.count < data.count ? compressed : nil)
        } else {
            out.bytes(data)
        }
    }

    /// A positive size means compressed data follows, and a negative size means uncompressed data.
    private static func writeSizedData(_ out: inout Out, _ data: [UInt8], _ compressed: [UInt8]?) {
        if let compressed {
            out.int64(compressed.count)
            out.bytes(compressed)
        } else {
            out.int64(-data.count)
            out.bytes(data)
        }
    }

    /// Compresses data in the zlib format (as java.util.zip.Deflater does by default).
    static func zlibCompress(_ data: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: data.count * 2 + 64)
        let n = data.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                compression_encode_buffer(dst.baseAddress!, dst.count, src.baseAddress ?? UnsafePointer(bitPattern: 1)!, src.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let adler = (b << 16) | a
        return [0x78, 0x9C] + output[0..<n] + [UInt8(adler >> 24), UInt8((adler >> 16) & 0xff), UInt8((adler >> 8) & 0xff), UInt8(adler & 0xff)]
    }

    /// Compresses in the Blosc version 1 format, with byte shuffling and the LZ4 codec, like OpenVDB does.
    static func bloscCompress(_ data: [UInt8], _ typeSize: Int, _ split: Bool) -> [UInt8] {
        let numBytes = data.count
        var out = Out()
        if numBytes < 128 {
            // Small buffers are stored without compression.
            out.int8(2)
            out.int8(1)
            out.int8(0x1 | 0x2 | (1 << 5))
            out.int8(typeSize)
            out.int32(numBytes)
            out.int32(numBytes)
            out.int32(16 + numBytes)
            out.bytes(data)
            return out.bytes
        }
        // Blosc rounds the block size down to a multiple of the type size, which leaves a
        // leftover block when the data size isn't a multiple of it.
        let blockSize = numBytes / typeSize * typeSize
        let leftover = numBytes % blockSize
        let numBlocks = numBytes / blockSize + (leftover > 0 ? 1 : 0)

        var blocks = Out()
        var blockStarts = [Int](repeating: 0, count: numBlocks)
        let headerSize = 16 + 4 * numBlocks
        for b in 0..<numBlocks {
            let isLeftover = leftover > 0 && b == numBlocks - 1
            let size = isLeftover ? leftover : blockSize
            let block = Array(data[(b * blockSize)..<(b * blockSize + size)])
            // shuffle
            var shuffled = [UInt8](repeating: 0, count: size)
            let numElements = size / typeSize
            for i in 0..<numElements {
                for j in 0..<typeSize {
                    shuffled[j * numElements + i] = block[i * typeSize + j]
                }
            }
            for k in (numElements * typeSize)..<size {
                shuffled[k] = block[k]
            }

            blockStarts[b] = headerSize + blocks.bytes.count
            let numSplits = split && typeSize <= 16 && size / typeSize >= 128 && !isLeftover ? typeSize : 1
            let splitSize = size / numSplits
            for s in 0..<numSplits {
                let compressed = lz4Compress(shuffled, s * splitSize, splitSize)
                if compressed.count >= splitSize {
                    blocks.int32(splitSize)
                    blocks.bytes(Array(shuffled[(s * splitSize)..<((s + 1) * splitSize)]))
                } else {
                    blocks.int32(compressed.count)
                    blocks.bytes(compressed)
                }
            }
        }
        out.int8(2)
        out.int8(1)
        out.int8(0x1 | (split ? 0 : 0x10) | (1 << 5))
        out.int8(typeSize)
        out.int32(numBytes)
        out.int32(blockSize)
        out.int32(headerSize + blocks.bytes.count)
        for start in blockStarts {
            out.int32(start)
        }
        out.bytes(blocks.bytes)
        return out.bytes
    }

    /// A simple greedy LZ4 block compressor.
    static func lz4Compress(_ src: [UInt8], _ offset: Int, _ length: Int) -> [UInt8] {
        var out = Out()
        var table = [Int](repeating: -1, count: 4096)
        let end = offset + length
        var anchor = offset
        var i = offset
        func readInt(_ i: Int) -> UInt32 {
            UInt32(src[i]) | UInt32(src[i + 1]) << 8 | UInt32(src[i + 2]) << 16 | UInt32(src[i + 3]) << 24
        }
        // The format requires the last 5 bytes to be literals, and the last match to start at least 12 bytes before the end.
        while i + 12 <= end {
            let seq = readInt(i)
            let hash = Int((seq &* 2654435761) >> 20)
            let ref = table[hash]
            table[hash] = i
            if ref >= 0 && i - ref <= 65535 && readInt(ref) == seq {
                var matchLength = 4
                while i + matchLength < end - 5 && src[ref + matchLength] == src[i + matchLength] {
                    matchLength += 1
                }
                writeSequence(&out, src, anchor, i - anchor, i - ref, matchLength)
                i += matchLength
                anchor = i
            } else {
                i += 1
            }
        }
        writeSequence(&out, src, anchor, end - anchor, 0, 0)
        return out.bytes
    }

    private static func writeSequence(_ out: inout Out, _ src: [UInt8], _ literalStart: Int, _ literalLength: Int,
                                      _ offset: Int, _ matchLength: Int) {
        let ml = matchLength > 0 ? matchLength - 4 : 0
        out.int8((min(literalLength, 15) << 4) | min(ml, 15))
        writeLength(&out, literalLength)
        out.bytes(Array(src[literalStart..<(literalStart + literalLength)]))
        if matchLength > 0 {
            out.int8(offset & 0xff)
            out.int8(offset >> 8)
            writeLength(&out, ml)
        }
    }

    private static func writeLength(_ out: inout Out, _ length: Int) {
        if length < 15 {
            return
        }
        var length = length - 15
        while length >= 255 {
            out.int8(255)
            length -= 255
        }
        out.int8(length)
    }

    static func floatToHalf(_ f: Float) -> UInt16 {
        let bits = f.bitPattern
        let sign = (bits >> 16) & 0x8000
        var val = (bits & 0x7fff_ffff) &+ 0x1000
        if val >= 0x4780_0000 {
            return UInt16(sign | 0x7c00)
        }
        if val >= 0x3880_0000 {
            return UInt16(truncatingIfNeeded: sign | ((val - 0x3800_0000) >> 13))
        }
        if val < 0x3300_0000 {
            return UInt16(sign)
        }
        val = (bits & 0x7fff_ffff) >> 23
        return UInt16(truncatingIfNeeded: sign | ((((bits & 0x7f_ffff) | 0x80_0000) + (0x80_0000 >> (val - 102))) >> (126 - val)))
    }

    private static func writeStringMeta(_ out: inout Out, _ name: String, _ value: String) {
        out.string(name)
        out.string("string")
        let bytes = Array(value.utf8)
        out.int32(bytes.count)
        out.bytes(bytes)
    }

    private static func floor(_ v: Int, _ log2: Int) -> Int {
        (v >> log2) << log2
    }

    private struct Out {
        var bytes: [UInt8] = []

        mutating func int8(_ v: Int) {
            bytes.append(UInt8(truncatingIfNeeded: v))
        }

        mutating func int16(_ v: Int) {
            for k in 0..<2 { bytes.append(UInt8(truncatingIfNeeded: v >> (k * 8))) }
        }

        mutating func int32(_ v: Int) {
            for k in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: v >> (k * 8))) }
        }

        mutating func int64(_ v: Int) {
            for k in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: v >> (k * 8))) }
        }

        mutating func value(_ v: Float, _ size: Int) {
            if size == 8 {
                int64(Int(Int64(bitPattern: Double(v).bitPattern)))
            } else {
                int32(Int(Int32(bitPattern: v.bitPattern)))
            }
        }

        mutating func values(_ values: [Float], _ size: Int) {
            for v in values {
                value(v, size)
            }
        }

        mutating func vec3d(_ v: [Double]) {
            for d in v {
                int64(Int(Int64(bitPattern: d.bitPattern)))
            }
        }

        mutating func coord(_ c: Coord) {
            int32(c.x)
            int32(c.y)
            int32(c.z)
        }

        mutating func string(_ s: String) {
            let b = Array(s.utf8)
            int32(b.count)
            bytes(b)
        }

        mutating func bytes(_ b: [UInt8]) {
            bytes.append(contentsOf: b)
        }

        mutating func mask(_ bits: [Bool]) {
            var b = [UInt8](repeating: 0, count: bits.count / 8)
            for i in 0..<bits.count where bits[i] {
                b[i >> 3] |= UInt8(1 << (i & 7))
            }
            bytes(b)
        }
    }
}

/// java.util.Random, so that tests use the same sequences of values as the original tests.
struct JavaRandom {
    private var seed: Int64

    init(_ seed: Int64) {
        self.seed = (seed ^ 0x5DEE_CE66D) & ((1 << 48) - 1)
    }

    private mutating func next(_ bits: Int) -> Int32 {
        seed = (seed &* 0x5DEE_CE66D &+ 0xB) & ((1 << 48) - 1)
        return Int32(truncatingIfNeeded: seed >> (48 - Int64(bits)))
    }

    mutating func nextInt(_ bound: Int) -> Int {
        let bound32 = Int32(bound)
        if bound32 & -bound32 == bound32 {
            return Int((Int64(bound32) * Int64(next(31))) >> 31)
        }
        var bits: Int32
        var val: Int32
        repeat {
            bits = next(31)
            val = bits % bound32
        } while bits &- val &+ (bound32 - 1) < 0
        return Int(val)
    }

    mutating func nextFloat() -> Float {
        Float(next(24)) / Float(1 << 24)
    }
}
