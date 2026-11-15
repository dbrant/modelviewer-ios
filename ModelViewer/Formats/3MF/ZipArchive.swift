//
//  ZipArchive.swift
//  ModelViewer
//
//  A minimal reader of ZIP archives (as used by 3MF files), which reads entries through the
//  archive's central directory (rather than sequentially), since some archives, such as those from
//  Bambu Studio, have uncompressed entries whose sizes are only given after their data.
//  Supports stored and deflated entries, and ZIP64 archives.
//
//  Info on the format: https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
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

struct ZipArchive {
    struct Entry {
        /// The name of the entry, as stored in the archive.
        let name: String
        let method: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private static let localHeaderSignature: UInt32 = 0x04034b50
    private static let centralHeaderSignature: UInt32 = 0x02014b50
    private static let endSignature: UInt32 = 0x06054b50
    private static let zip64EndSignature: UInt32 = 0x06064b50
    private static let zip64LocatorSignature: UInt32 = 0x07064b50
    private static let invalidArchive = ModelError("Not a valid ZIP archive.")

    private let data: Data
    /// The entries, in the order of the central directory.
    let entries: [Entry]
    /// The entries, by their normalized paths (see `normalizePath`).
    private let entriesByPath: [String: Entry]

    init(data: Data) throws {
        let data = data.rebased
        self.data = data
        let reader = BinaryReader(data)

        // The end of central directory record is at the end of the archive, followed by a comment of up to 64 KB.
        let endOffset = try Self.findEndRecord(reader)
        var entryCount = Int(reader.uint16LE(at: endOffset + 10))
        var directorySize = Int(reader.uint32LE(at: endOffset + 12))
        var directoryOffset = Int(reader.uint32LE(at: endOffset + 16))

        // A ZIP64 archive has a locator just before the end record, which gives the position of the ZIP64 end record.
        if endOffset >= 20 && reader.uint32LE(at: endOffset - 20) == Self.zip64LocatorSignature {
            let zip64Offset = Int(clamping: reader.uint64LE(at: endOffset - 20 + 8))
            if zip64Offset >= 0 && zip64Offset <= data.count - 56 && reader.uint32LE(at: zip64Offset) == Self.zip64EndSignature {
                entryCount = Int(clamping: reader.uint64LE(at: zip64Offset + 32))
                directorySize = Int(clamping: reader.uint64LE(at: zip64Offset + 40))
                directoryOffset = Int(clamping: reader.uint64LE(at: zip64Offset + 48))
            }
        }
        if directoryOffset < 0 || directorySize < 0 || directoryOffset > data.count - directorySize {
            throw Self.invalidArchive
        }

        var entries: [Entry] = []
        var byPath: [String: Entry] = [:]
        var r = BinaryReader(data, position: directoryOffset)
        let directoryEnd = directoryOffset + directorySize
        while r.position + 46 <= directoryEnd && entries.count < max(entryCount, 1) * 2 {
            guard try r.readUInt32LE() == Self.centralHeaderSignature else {
                break
            }
            try r.skip(6) // versions, flags
            let method = Int(try r.readUInt16LE())
            try r.skip(8) // time, date, CRC
            var compressedSize = Int(try r.readUInt32LE())
            var uncompressedSize = Int(try r.readUInt32LE())
            let nameLength = Int(try r.readUInt16LE())
            let extraLength = Int(try r.readUInt16LE())
            let commentLength = Int(try r.readUInt16LE())
            try r.skip(8) // disk number, attributes
            var localHeaderOffset = Int(try r.readUInt32LE())
            let nameBytes = try r.readData(nameLength)
            let extra = try r.readData(extraLength)
            try r.skip(commentLength)

            // Sizes and offsets that don't fit in 32 bits are given in the ZIP64 extra field, in this order.
            if compressedSize == 0xFFFFFFFF || uncompressedSize == 0xFFFFFFFF || localHeaderOffset == 0xFFFFFFFF {
                var e = BinaryReader(extra)
                while e.remaining >= 4 {
                    let id = try e.readUInt16LE()
                    let size = Int(try e.readUInt16LE())
                    guard size <= e.remaining else { break }
                    if id == 0x0001 {
                        var field = BinaryReader(try e.readData(size))
                        if uncompressedSize == 0xFFFFFFFF, field.remaining >= 8 {
                            uncompressedSize = Int(clamping: try field.readUInt64LE())
                        }
                        if compressedSize == 0xFFFFFFFF, field.remaining >= 8 {
                            compressedSize = Int(clamping: try field.readUInt64LE())
                        }
                        if localHeaderOffset == 0xFFFFFFFF, field.remaining >= 8 {
                            localHeaderOffset = Int(clamping: try field.readUInt64LE())
                        }
                        break
                    }
                    try e.skip(size)
                }
            }

            let name = String(data: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self)
            let entry = Entry(name: name, method: method, compressedSize: compressedSize,
                              uncompressedSize: uncompressedSize, localHeaderOffset: localHeaderOffset)
            entries.append(entry)
            let path = Self.normalizePath(name)
            if byPath[path] == nil {
                byPath[path] = entry
            }
        }
        if entries.isEmpty && entryCount > 0 {
            throw Self.invalidArchive
        }
        self.entries = entries
        self.entriesByPath = byPath
    }

    private static func findEndRecord(_ reader: BinaryReader) throws -> Int {
        let count = reader.count
        if count < 22 {
            throw invalidArchive
        }
        let lowest = max(0, count - 22 - 0xFFFF)
        var offset = count - 22
        while offset >= lowest {
            if reader.uint32LE(at: offset) == endSignature {
                // The comment must extend exactly to the end of the archive (but be lenient about trailing bytes).
                return offset
            }
            offset -= 1
        }
        throw invalidArchive
    }

    /// Part names in a package are case-insensitive, and may be given with a leading slash.
    static func normalizePath(_ path: String) -> String {
        var p = Substring(path)
        while p.hasPrefix("/") {
            p = p.dropFirst()
        }
        return p.lowercased()
    }

    func entry(_ path: String) -> Entry? {
        entriesByPath[Self.normalizePath(path)]
    }

    func contains(_ path: String) -> Bool {
        entry(path) != nil
    }

    /// Returns the decompressed contents of the entry with the given path, or nil if there's no such entry.
    func read(_ path: String) throws -> Data? {
        guard let entry = entry(path) else {
            return nil
        }
        return try read(entry)
    }

    func read(_ entry: Entry) throws -> Data {
        let reader = BinaryReader(data)
        let offset = entry.localHeaderOffset
        guard offset >= 0, offset <= data.count - 30, reader.uint32LE(at: offset) == Self.localHeaderSignature else {
            throw Self.invalidArchive
        }
        // The sizes come from the central directory, since the local header may not have them.
        let nameLength = Int(reader.uint16LE(at: offset + 26))
        let extraLength = Int(reader.uint16LE(at: offset + 28))
        let start = offset + 30 + nameLength + extraLength
        guard entry.compressedSize >= 0, start <= data.count - entry.compressedSize else {
            throw Self.invalidArchive
        }
        let compressed = data.subdata(in: start..<(start + entry.compressedSize))
        switch entry.method {
        case 0:
            return compressed
        case 8:
            return try Inflater.inflate(compressed, zlibWrapped: false, expectedSize: entry.uncompressedSize)
        default:
            throw ModelError("Unsupported compression method in ZIP archive: \(entry.method)")
        }
    }
}
