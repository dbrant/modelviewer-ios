//
//  Blosc.swift
//  ModelViewer
//
//  Decompressor for the Blosc (version 1) format, as used by OpenVDB, which supports the LZ4
//  codec, with or without byte shuffling. See https://github.com/Blosc/c-blosc
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

final class Blosc {
    private static let headerSize = 16
    private static let flagShuffle = 0x1
    private static let flagMemcpyed = 0x2
    private static let flagBitshuffle = 0x4
    private static let flagDontSplit = 0x10
    private static let compressorLz4 = 1
    private static let maxSplits = 16
    private static let minBufferSize = 128

    private var shuffleBuffer: [UInt8] = []

    /// Decompresses `srcLength` bytes of `src` into the first `destLength` bytes of `dest`.
    func decompress(_ src: [UInt8], _ srcLength: Int, _ dest: inout [UInt8], _ destLength: Int) throws {
        try src.withUnsafeBufferPointer { s in
            try dest.withUnsafeMutableBufferPointer { d in
                try decompress(s.baseAddress!, srcLength, d.baseAddress!, destLength)
            }
        }
    }

    func decompress(_ src: UnsafePointer<UInt8>, _ srcLength: Int, _ dest: UnsafeMutablePointer<UInt8>, _ destLength: Int) throws {
        func readInt(_ offset: Int) -> Int {
            Int(Int32(bitPattern: UInt32(src[offset]) | UInt32(src[offset + 1]) << 8 |
                      UInt32(src[offset + 2]) << 16 | UInt32(src[offset + 3]) << 24))
        }
        if srcLength < Self.headerSize {
            throw ModelError("Invalid Blosc buffer.")
        }
        let flags = Int(src[2])
        let typeSize = Int(src[3])
        let numBytes = readInt(4)
        let blockSize = readInt(8)
        if numBytes != destLength {
            throw ModelError("Unexpected Blosc buffer size: \(numBytes), expected \(destLength).")
        }
        if numBytes == 0 {
            return
        }
        if flags & Self.flagMemcpyed != 0 {
            if Self.headerSize + numBytes > srcLength {
                throw ModelError("Truncated Blosc buffer.")
            }
            dest.update(from: src + Self.headerSize, count: numBytes)
            return
        }
        if (flags & 0xe0) >> 5 != Self.compressorLz4 {
            throw ModelError("Unsupported Blosc compressor: \((flags & 0xe0) >> 5)")
        }
        if flags & Self.flagBitshuffle != 0 {
            throw ModelError("Blosc bit-shuffling is not supported.")
        }
        if blockSize <= 0 || typeSize <= 0 {
            throw ModelError("Invalid Blosc header.")
        }
        let doShuffle = (flags & Self.flagShuffle != 0) && typeSize > 1
        let dontSplit = flags & Self.flagDontSplit != 0
        let leftover = numBytes % blockSize
        let numBlocks = numBytes / blockSize + (leftover > 0 ? 1 : 0)
        if Self.headerSize + numBlocks * 4 > srcLength {
            throw ModelError("Truncated Blosc buffer.")
        }
        if doShuffle && shuffleBuffer.count < blockSize {
            shuffleBuffer = [UInt8](repeating: 0, count: blockSize)
        }

        try shuffleBuffer.withUnsafeMutableBufferPointer { shuffle in
            let temp = doShuffle ? shuffle.baseAddress! : dest
            for block in 0..<numBlocks {
                let isLeftover = leftover > 0 && block == numBlocks - 1
                let currentBlockSize = isLeftover ? leftover : blockSize
                let destOffset = block * blockSize
                var srcPos = readInt(Self.headerSize + block * 4)
                let numSplits = (!dontSplit && typeSize <= Self.maxSplits && !isLeftover
                                 && currentBlockSize / typeSize >= Self.minBufferSize) ? typeSize : 1
                let splitSize = currentBlockSize / numSplits
                var outPos = doShuffle ? 0 : destOffset

                for _ in 0..<numSplits {
                    if srcPos < 0 || srcPos + 4 > srcLength {
                        throw ModelError("Truncated Blosc buffer.")
                    }
                    let compressedSize = readInt(srcPos)
                    srcPos += 4
                    if compressedSize < 0 || srcPos + compressedSize > srcLength {
                        throw ModelError("Truncated Blosc buffer.")
                    }
                    if compressedSize == splitSize {
                        (temp + outPos).update(from: src + srcPos, count: splitSize)
                    } else if try Self.lz4Decompress(src, srcPos, compressedSize, temp, outPos, splitSize) != splitSize {
                        throw ModelError("Corrupt LZ4 data in Blosc buffer.")
                    }
                    srcPos += compressedSize
                    outPos += splitSize
                }
                if doShuffle {
                    Self.unshuffle(typeSize, currentBlockSize, temp, dest, destOffset)
                }
            }
        }
    }

    private static func unshuffle(_ typeSize: Int, _ blockSize: Int, _ src: UnsafeMutablePointer<UInt8>,
                                  _ dest: UnsafeMutablePointer<UInt8>, _ destOffset: Int) {
        let numElements = blockSize / typeSize
        let out = dest + destOffset
        for j in 0..<typeSize {
            let column = src + j * numElements
            var p = out + j
            for i in 0..<numElements {
                p.pointee = column[i]
                p += typeSize
            }
        }
        // Leftover bytes at the end of the block are not shuffled.
        let shuffledBytes = numElements * typeSize
        (out + shuffledBytes).update(from: src + shuffledBytes, count: blockSize - shuffledBytes)
    }

    /// Decompresses a raw LZ4 block, and returns the number of bytes written.
    private static func lz4Decompress(_ src: UnsafePointer<UInt8>, _ srcOffset: Int, _ srcLength: Int,
                                      _ dest: UnsafeMutablePointer<UInt8>, _ destOffset: Int, _ destLength: Int) throws -> Int {
        let srcEnd = srcOffset + srcLength
        let destEnd = destOffset + destLength
        var sp = srcOffset
        var dp = destOffset
        let corrupt = ModelError("Corrupt LZ4 data.")
        while sp < srcEnd {
            let token = Int(src[sp])
            sp += 1

            var literalLength = token >> 4
            if literalLength == 15 {
                var b: Int
                repeat {
                    if sp >= srcEnd { throw corrupt }
                    b = Int(src[sp])
                    sp += 1
                    literalLength += b
                } while b == 255
            }
            if sp + literalLength > srcEnd || dp + literalLength > destEnd {
                throw corrupt
            }
            (dest + dp).update(from: src + sp, count: literalLength)
            sp += literalLength
            dp += literalLength
            if sp >= srcEnd {
                // The last sequence contains only literals.
                break
            }

            if sp + 2 > srcEnd { throw corrupt }
            let offset = Int(src[sp]) | (Int(src[sp + 1]) << 8)
            sp += 2
            var matchLength = token & 0xf
            if matchLength == 15 {
                var b: Int
                repeat {
                    if sp >= srcEnd { throw corrupt }
                    b = Int(src[sp])
                    sp += 1
                    matchLength += b
                } while b == 255
            }
            matchLength += 4
            var mp = dp - offset
            if offset == 0 || mp < destOffset || dp + matchLength > destEnd {
                throw corrupt
            }
            if offset >= matchLength {
                (dest + dp).update(from: dest + mp, count: matchLength)
                dp += matchLength
            } else {
                // Overlapping match, which repeats the preceding bytes.
                let end = dp + matchLength
                while dp < end {
                    dest[dp] = dest[mp]
                    dp += 1
                    mp += 1
                }
            }
        }
        return dp - destOffset
    }
}
