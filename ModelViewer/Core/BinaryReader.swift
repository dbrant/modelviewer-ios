//
//  BinaryReader.swift
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

/// Sequential reader of binary data, in either byte order. Reads past the end throw `ModelError.unexpectedEnd`.
struct BinaryReader {
    /// The data, with indices starting at zero.
    let data: Data
    var position = 0

    init(_ data: Data, position: Int = 0) {
        self.data = data.startIndex == 0 ? data : Data(data)
        self.position = position
    }

    var count: Int { data.count }
    var remaining: Int { data.count - position }
    var isAtEnd: Bool { position >= data.count }

    @inline(__always)
    private mutating func advance(_ n: Int) throws -> Int {
        guard n >= 0, position <= data.count - n else {
            throw ModelError.unexpectedEnd
        }
        let p = position
        position += n
        return p
    }

    @inline(__always)
    private func load<T: FixedWidthInteger>(_ offset: Int, as type: T.Type) -> T {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    }

    mutating func skip(_ n: Int) throws {
        _ = try advance(n)
    }

    mutating func readUInt8() throws -> UInt8 {
        data[try advance(1)]
    }

    mutating func readInt8() throws -> Int8 {
        Int8(bitPattern: try readUInt8())
    }

    mutating func readUInt16LE() throws -> UInt16 { UInt16(littleEndian: load(try advance(2), as: UInt16.self)) }
    mutating func readUInt16BE() throws -> UInt16 { UInt16(bigEndian: load(try advance(2), as: UInt16.self)) }
    mutating func readInt16LE() throws -> Int16 { Int16(bitPattern: try readUInt16LE()) }
    mutating func readInt16BE() throws -> Int16 { Int16(bitPattern: try readUInt16BE()) }
    mutating func readUInt32LE() throws -> UInt32 { UInt32(littleEndian: load(try advance(4), as: UInt32.self)) }
    mutating func readUInt32BE() throws -> UInt32 { UInt32(bigEndian: load(try advance(4), as: UInt32.self)) }
    mutating func readInt32LE() throws -> Int32 { Int32(bitPattern: try readUInt32LE()) }
    mutating func readInt32BE() throws -> Int32 { Int32(bitPattern: try readUInt32BE()) }
    mutating func readUInt64LE() throws -> UInt64 { UInt64(littleEndian: load(try advance(8), as: UInt64.self)) }
    mutating func readUInt64BE() throws -> UInt64 { UInt64(bigEndian: load(try advance(8), as: UInt64.self)) }
    mutating func readInt64LE() throws -> Int64 { Int64(bitPattern: try readUInt64LE()) }
    mutating func readInt64BE() throws -> Int64 { Int64(bitPattern: try readUInt64BE()) }
    mutating func readFloatLE() throws -> Float { Float(bitPattern: try readUInt32LE()) }
    mutating func readFloatBE() throws -> Float { Float(bitPattern: try readUInt32BE()) }
    mutating func readDoubleLE() throws -> Double { Double(bitPattern: try readUInt64LE()) }
    mutating func readDoubleBE() throws -> Double { Double(bitPattern: try readUInt64BE()) }

    /// Reads the given number of bytes.
    mutating func readData(_ n: Int) throws -> Data {
        let p = try advance(n)
        return data.subdata(in: p..<(p + n))
    }

    mutating func readBytes(_ n: Int) throws -> [UInt8] {
        let p = try advance(n)
        return [UInt8](data[p..<(p + n)])
    }

    /// Reads a string of the given number of bytes (as UTF-8, or else Latin-1).
    mutating func readString(_ n: Int) throws -> String {
        let bytes = try readData(n)
        return String(data: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
    }

    // Random access, which doesn't change the position.

    func uint16LE(at offset: Int) -> UInt16 { UInt16(littleEndian: load(offset, as: UInt16.self)) }
    func uint32LE(at offset: Int) -> UInt32 { UInt32(littleEndian: load(offset, as: UInt32.self)) }
    func uint32BE(at offset: Int) -> UInt32 { UInt32(bigEndian: load(offset, as: UInt32.self)) }
    func uint64LE(at offset: Int) -> UInt64 { UInt64(littleEndian: load(offset, as: UInt64.self)) }
    func floatLE(at offset: Int) -> Float { Float(bitPattern: uint32LE(at: offset)) }
    func doubleLE(at offset: Int) -> Double { Double(bitPattern: uint64LE(at: offset)) }
}

extension Data {
    /// The data with indices starting at zero (slices of Data keep the indices of the original).
    var rebased: Data { startIndex == 0 ? self : Data(self) }

    func uint16LE(at offset: Int) -> UInt16 {
        withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }

    func uint32LE(at offset: Int) -> UInt32 {
        withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    func floatLE(at offset: Int) -> Float {
        Float(bitPattern: uint32LE(at: offset))
    }
}
