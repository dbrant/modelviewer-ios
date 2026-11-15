//
//  Inflater.swift
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
import Compression

/// Decompression of Deflate data (as in ZIP, FBX, and VDB files), like java.util.zip.Inflater.
enum Inflater {
    /// Decompresses data that's compressed with Deflate.
    ///
    /// - Parameters:
    ///   - data: The compressed data.
    ///   - zlibWrapped: Whether the data has a zlib header (RFC 1950), as opposed to raw Deflate data (RFC 1951).
    ///   - expectedSize: The size of the decompressed data, if it's known, which saves reallocating the output.
    ///     The output is not limited to this size.
    static func inflate(_ data: Data, zlibWrapped: Bool, expectedSize: Int? = nil) throws -> Data {
        var input = data.rebased
        if zlibWrapped {
            // The zlib header is two bytes (plus a dictionary ID, if the FDICT flag is set, which isn't supported).
            let cmf = input.count >= 2 ? Int(input[0]) : 0
            let flg = input.count >= 2 ? Int(input[1]) : 0
            guard input.count >= 2, (cmf * 256 + flg) % 31 == 0, cmf & 0x0f == 8 else {
                throw ModelError("Invalid compressed data.")
            }
            if flg & 0x20 != 0 {
                throw ModelError("Compressed data with a preset dictionary isn't supported.")
            }
            input = input.subdata(in: 2..<input.count)
        }
        if input.isEmpty {
            return Data()
        }

        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ModelError("Unable to decompress data.")
        }
        defer { compression_stream_destroy(streamPointer) }

        let chunkSize = max(min(expectedSize ?? (input.count * 4), 64 << 20), 4096)
        var output = Data()
        output.reserveCapacity(expectedSize ?? input.count * 4)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        try input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            streamPointer.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            streamPointer.pointee.src_size = src.count
            while true {
                streamPointer.pointee.dst_ptr = buffer
                streamPointer.pointee.dst_size = chunkSize
                let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - streamPointer.pointee.dst_size
                if produced > 0 {
                    output.append(buffer, count: produced)
                }
                switch status {
                case COMPRESSION_STATUS_OK:
                    // If no progress can be made, the data is truncated.
                    if produced == 0 && streamPointer.pointee.src_size == 0 {
                        return
                    }
                case COMPRESSION_STATUS_END:
                    return
                default:
                    throw ModelError("Invalid compressed data.")
                }
            }
        }
        return output
    }
}
