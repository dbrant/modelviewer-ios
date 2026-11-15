//
//  FbxParser.swift
//  ModelViewer
//
//  Parser for FBX files, in their binary and ASCII forms, which reads them into a tree of nodes.
//  Nodes with data that isn't needed for displaying a model (animations and poses) are skipped.
//
//  Info on the binary format: https://code.blender.org/2013/08/fbx-binary-file-format-specification/
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

enum FbxParser {
    /// A parsed file: its format version (e.g. 7400 for version 7.4), and its top-level nodes.
    final class Document {
        let version: Int
        let nodes: [FbxNode]

        init(version: Int, nodes: [FbxNode]) {
            self.version = version
            self.nodes = nodes
        }

        func node(_ name: String) -> FbxNode? {
            nodes.first { $0.name == name }
        }
    }

    private static let binaryMagic: [UInt8] = Array("Kaydara FBX Binary  ".utf8) + [0]
    private static let binaryHeaderSize = 27

    /// Nodes that aren't needed for displaying a model, which are skipped.
    fileprivate static let skippedNodes: Set<String> = ["Takes", "AnimationStack", "AnimationLayer", "AnimationCurveNode", "AnimationCurve", "Pose"]

    static func parse(_ data: Data) throws -> Document {
        let bytes = [UInt8](data)
        if bytes.count >= binaryHeaderSize && Array(bytes[0..<binaryMagic.count]) == binaryMagic {
            let version = Int(Int32(bitPattern: UInt32(bytes[23]) | UInt32(bytes[24]) << 8 | UInt32(bytes[25]) << 16 | UInt32(bytes[26]) << 24))
            let parser = BinaryParser(bytes: bytes, version: version)
            return Document(version: version, nodes: try parser.readNodes(start: binaryHeaderSize, end: bytes.count))
        }
        let parser = AsciiParser(bytes: bytes)
        let nodes = try parser.readNodes(topLevel: true)
        if !nodes.contains(where: { $0.name == "Objects" }) {
            throw ModelError("Not a valid FBX file.")
        }
        let version = nodes.first { $0.name == "FBXHeaderExtension" }?.child("FBXVersion")?.number(0).map { FbxNode.toInt32($0) } ?? 7000
        return Document(version: version, nodes: nodes)
    }

    private final class BinaryParser {
        private let bytes: [UInt8]
        // Starting with version 7.5, offsets and counts are 64 bits.
        private let wide: Bool
        private let headerSize: Int

        init(bytes: [UInt8], version: Int) {
            self.bytes = bytes
            self.wide = version >= 7500
            self.headerSize = wide ? 25 : 13
        }

        private func check(_ p: Int, _ n: Int) throws {
            if p < 0 || n < 0 || p > bytes.count - n {
                throw ModelError("Invalid FBX file.")
            }
        }

        private func u32(_ p: Int) -> UInt32 {
            bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: p, as: UInt32.self)) }
        }

        private func u64(_ p: Int) -> UInt64 {
            bytes.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: p, as: UInt64.self)) }
        }

        func readNodes(start: Int, end: Int) throws -> [FbxNode] {
            var nodes: [FbxNode] = []
            var pos = start
            while pos + headerSize <= end {
                try check(pos, headerSize)
                let endOffset: UInt64 = wide ? u64(pos) : UInt64(u32(pos))
                if endOffset == 0 {
                    // A null record ends a list of nodes.
                    break
                }
                let propertyCount: UInt64 = wide ? u64(pos + 8) : UInt64(u32(pos + 4))
                let nameLength = Int(bytes[pos + headerSize - 1])
                if endOffset <= UInt64(pos) || endOffset > UInt64(end) || propertyCount > UInt64(Int32.max) {
                    throw ModelError("Invalid FBX node.")
                }
                try check(pos + headerSize, nameLength)
                let name = String(bytes: bytes[(pos + headerSize)..<(pos + headerSize + nameLength)], encoding: .isoLatin1) ?? ""
                if !FbxParser.skippedNodes.contains(name) {
                    var p = pos + headerSize + nameLength
                    var properties: [FbxValue] = []
                    properties.reserveCapacity(Int(propertyCount))
                    for _ in 0..<Int(propertyCount) {
                        p = try readProperty(p, &properties)
                    }
                    let children = p < Int(endOffset) ? try readNodes(start: p, end: Int(endOffset)) : []
                    nodes.append(FbxNode(name: name, properties: properties, children: children))
                }
                pos = Int(endOffset)
            }
            return nodes
        }

        /// Reads a property into the list, and returns the position after it.
        private func readProperty(_ start: Int, _ properties: inout [FbxValue]) throws -> Int {
            var p = start
            try check(p, 1)
            let type = bytes[p]
            p += 1
            switch type {
            case UInt8(ascii: "Y"):
                try check(p, 2)
                properties.append(.short(Int16(bitPattern: UInt16(bytes[p]) | UInt16(bytes[p + 1]) << 8)))
                p += 2
            case UInt8(ascii: "C"):
                try check(p, 1)
                properties.append(.bool(bytes[p] != 0))
                p += 1
            case UInt8(ascii: "I"):
                try check(p, 4)
                properties.append(.int(Int32(bitPattern: u32(p))))
                p += 4
            case UInt8(ascii: "F"):
                try check(p, 4)
                properties.append(.float(Float(bitPattern: u32(p))))
                p += 4
            case UInt8(ascii: "D"):
                try check(p, 8)
                properties.append(.double(Double(bitPattern: u64(p))))
                p += 8
            case UInt8(ascii: "L"):
                try check(p, 8)
                properties.append(.long(Int64(bitPattern: u64(p))))
                p += 8
            case UInt8(ascii: "f"), UInt8(ascii: "d"), UInt8(ascii: "l"), UInt8(ascii: "i"), UInt8(ascii: "b"):
                try check(p, 12)
                let length = Int(Int32(bitPattern: u32(p)))
                let encoding = Int(Int32(bitPattern: u32(p + 4)))
                let storedLength = Int(Int32(bitPattern: u32(p + 8)))
                p += 12
                let elementSize: Int
                switch type {
                case UInt8(ascii: "d"), UInt8(ascii: "l"): elementSize = 8
                case UInt8(ascii: "f"), UInt8(ascii: "i"): elementSize = 4
                default: elementSize = 1
                }
                if length < 0 || storedLength < 0 || length * elementSize > Int(Int32.max) {
                    throw ModelError("Invalid FBX array.")
                }
                let byteCount = length * elementSize
                try check(p, encoding == 1 ? storedLength : byteCount)
                let values: [UInt8]
                if encoding == 1 {
                    let inflated = try Inflater.inflate(Data(bytes[p..<(p + storedLength)]), zlibWrapped: true, expectedSize: byteCount)
                    if inflated.count < byteCount {
                        throw ModelError("Invalid compressed FBX array.")
                    }
                    values = [UInt8](inflated.prefix(byteCount))
                } else {
                    values = Array(bytes[p..<(p + byteCount)])
                }
                properties.append(Self.makeArray(type, values, length))
                p += storedLength
            case UInt8(ascii: "S"), UInt8(ascii: "R"):
                try check(p, 4)
                let length = Int(Int32(bitPattern: u32(p)))
                p += 4
                if length < 0 || p + length > bytes.count {
                    throw ModelError("Invalid FBX property.")
                }
                let slice = bytes[p..<(p + length)]
                if type == UInt8(ascii: "S") {
                    properties.append(.string(String(decoding: slice, as: UTF8.self)))
                } else {
                    properties.append(.bytes(Data(slice)))
                }
                p += length
            default:
                throw ModelError("Unknown FBX property type: \(Character(Unicode.Scalar(type)))")
            }
            return p
        }

        private static func makeArray(_ type: UInt8, _ values: [UInt8], _ length: Int) -> FbxValue {
            func load<T>(_: T.Type) -> [T] {
                [T](unsafeUninitializedCapacity: length) { buffer, count in
                    values.withUnsafeBytes { src in
                        if length > 0 {
                            UnsafeMutableRawPointer(buffer.baseAddress!).copyMemory(from: src.baseAddress!, byteCount: length * MemoryLayout<T>.size)
                        }
                    }
                    count = length
                }
            }
            // The data is little-endian, as are the platforms on which the app runs.
            switch type {
            case UInt8(ascii: "f"): return .floats(load(Float.self))
            case UInt8(ascii: "d"): return .doubles(load(Double.self))
            case UInt8(ascii: "l"): return .longs(load(Int64.self))
            case UInt8(ascii: "i"): return .ints(load(Int32.self))
            default: return .bools(values.prefix(length).map { $0 != 0 })
            }
        }
    }

    /// Parser for ASCII files, which have lines like "Name: value, value, ... {", with child nodes
    /// up to a closing brace. Lists of values may continue on the next line after a comma.
    private final class AsciiParser {
        private let data: [UInt8]
        private var pos = 0

        // Values of the node that's being read: numbers are collected without boxing them, unless
        // the node also has other kinds of values.
        private var longs: [Int64] = []
        private var doubles: [Double] = []
        private var allIntegers = true
        private var mixed: [FbxValue]?
        private var longValue: Int64 = 0
        private var doubleValue = 0.0
        private var isInteger = false

        private static let space = UInt8(ascii: " ")
        private static let tab = UInt8(ascii: "\t")
        private static let cr = UInt8(ascii: "\r")
        private static let lf = UInt8(ascii: "\n")
        private static let quote = UInt8(ascii: "\"")
        private static let colon = UInt8(ascii: ":")
        private static let comma = UInt8(ascii: ",")
        private static let semicolon = UInt8(ascii: ";")
        private static let openBrace = UInt8(ascii: "{")
        private static let closeBrace = UInt8(ascii: "}")

        init(bytes: [UInt8]) {
            self.data = bytes
        }

        func readNodes(topLevel: Bool) throws -> [FbxNode] {
            var nodes: [FbxNode] = []
            while true {
                skipWhitespace(newlines: true)
                if pos >= data.count {
                    if !topLevel {
                        throw ModelError("Unexpected end of FBX file.")
                    }
                    break
                }
                if data[pos] == Self.closeBrace {
                    pos += 1
                    if topLevel {
                        throw ModelError("Unexpected end of FBX node.")
                    }
                    break
                }
                let nameStart = pos
                while pos < data.count && data[pos] != Self.colon && !isWhitespace(data[pos]) {
                    pos += 1
                }
                if pos >= data.count || data[pos] != Self.colon {
                    throw ModelError("Invalid FBX file.")
                }
                let name = String(bytes: data[nameStart..<pos], encoding: .isoLatin1) ?? ""
                pos += 1
                if FbxParser.skippedNodes.contains(name) {
                    try skipNode()
                    continue
                }
                let properties = try readValues()
                skipWhitespace(newlines: false)
                let children: [FbxNode]
                if pos < data.count && data[pos] == Self.openBrace {
                    pos += 1
                    children = try readNodes(topLevel: false)
                } else {
                    children = []
                }
                nodes.append(FbxNode(name: name, properties: properties, children: children))
            }
            return nodes
        }

        /// Reads the values of a node, up to the end of its line, or the start of its children.
        private func readValues() throws -> [FbxValue] {
            longs.removeAll(keepingCapacity: true)
            doubles.removeAll(keepingCapacity: true)
            allIntegers = true
            mixed = nil
            var afterComma = false
            loop: while pos < data.count {
                let c = data[pos]
                switch c {
                case Self.space, Self.tab, Self.cr:
                    pos += 1
                case Self.lf:
                    // The values continue on the next line after a comma, at the end of the
                    // line, or at the start of the next line (as in some files of version 6).
                    if !afterComma && !nextLineStartsWithComma() {
                        break loop
                    }
                    pos += 1
                case Self.semicolon:
                    skipLine()
                case Self.openBrace, Self.closeBrace:
                    break loop
                case Self.comma:
                    afterComma = true
                    pos += 1
                case Self.quote:
                    let end = try indexOf(Self.quote, from: pos + 1)
                    let string = String(decoding: data[(pos + 1)..<end], as: UTF8.self).replacingOccurrences(of: "&quot;", with: "\"")
                    addValue(.string(string))
                    pos = end + 1
                    afterComma = false
                default:
                    let start = pos
                    while pos < data.count && !isDelimiter(data[pos]) {
                        pos += 1
                    }
                    // The length of an array is written as "*123", before its values (in an "a" node).
                    if c != UInt8(ascii: "*") {
                        if parseNumber(start, pos) {
                            addNumber()
                        } else {
                            addValue(.string(String(bytes: data[start..<pos], encoding: .isoLatin1) ?? ""))
                        }
                    }
                    afterComma = false
                }
            }
            if let mixed {
                return mixed
            }
            if longs.isEmpty {
                return []
            }
            return allIntegers ? [.longs(longs)] : [.doubles(doubles)]
        }

        private func addNumber() {
            if mixed != nil {
                mixed!.append(isInteger ? .long(longValue) : .double(doubleValue))
                return
            }
            longs.append(longValue)
            doubles.append(doubleValue)
            allIntegers = allIntegers && isInteger
        }

        private func addValue(_ value: FbxValue) {
            if mixed == nil {
                var values: [FbxValue] = []
                values.reserveCapacity(longs.count + 1)
                for i in 0..<longs.count {
                    if allIntegers || doubles[i] == Double(longs[i]) {
                        values.append(.long(longs[i]))
                    } else {
                        values.append(.double(doubles[i]))
                    }
                }
                mixed = values
            }
            mixed!.append(value)
        }

        /// Parses a number from the given range of the data, into `longValue`, `doubleValue`, and
        /// `isInteger`, and returns whether it's a number.
        private func parseNumber(_ start: Int, _ end: Int) -> Bool {
            var i = start
            let negative = data[i] == UInt8(ascii: "-")
            if negative || data[i] == UInt8(ascii: "+") {
                i += 1
            }
            var mantissa: Int64 = 0
            var digits = 0
            var fractionDigits = 0
            isInteger = true
            while i < end && isDigit(data[i]) {
                mantissa = mantissa &* 10 &+ Int64(data[i] - 0x30)
                digits += 1
                i += 1
            }
            if i < end && data[i] == UInt8(ascii: ".") {
                isInteger = false
                i += 1
                while i < end && isDigit(data[i]) {
                    mantissa = mantissa &* 10 &+ Int64(data[i] - 0x30)
                    digits += 1
                    fractionDigits += 1
                    i += 1
                }
            }
            var exponent = 0
            if digits > 0 && i < end && (data[i] == UInt8(ascii: "e") || data[i] == UInt8(ascii: "E")) {
                isInteger = false
                i += 1
                let negativeExponent = i < end && data[i] == UInt8(ascii: "-")
                if i < end && (data[i] == UInt8(ascii: "-") || data[i] == UInt8(ascii: "+")) {
                    i += 1
                }
                while i < end && isDigit(data[i]) {
                    exponent = min(exponent &* 10 &+ Int(data[i] - 0x30), 100_000)
                    i += 1
                }
                if negativeExponent {
                    exponent = -exponent
                }
            }
            if i != end || digits == 0 {
                return false
            }
            if digits > 18 {
                // Too many digits to collect in an Int64.
                doubleValue = Double(String(decoding: data[start..<end], as: UTF8.self)) ?? 0
                longValue = FbxNode.toInt64(doubleValue)
                isInteger = false
                return true
            }
            if negative {
                mantissa = -mantissa
            }
            let scale = exponent - fractionDigits
            if scale == 0 {
                doubleValue = Double(mantissa)
            } else if scale > 0 {
                doubleValue = Double(mantissa) * pow(10.0, Double(scale))
            } else {
                doubleValue = Double(mantissa) / pow(10.0, Double(-scale))
            }
            longValue = isInteger ? mantissa : FbxNode.toInt64(doubleValue)
            return true
        }

        /// Skips a node and all of its children, without reading them.
        private func skipNode() throws {
            _ = try readValues()
            skipWhitespace(newlines: false)
            if pos >= data.count || data[pos] != Self.openBrace {
                return
            }
            var depth = 0
            while pos < data.count {
                switch data[pos] {
                case Self.openBrace:
                    depth += 1
                case Self.closeBrace:
                    depth -= 1
                    if depth == 0 {
                        pos += 1
                        return
                    }
                case Self.quote:
                    pos = try indexOf(Self.quote, from: pos + 1)
                case Self.semicolon:
                    skipLine()
                default:
                    break
                }
                pos += 1
            }
            throw ModelError("Unexpected end of FBX file.")
        }

        private func skipWhitespace(newlines: Bool) {
            while pos < data.count {
                let b = data[pos]
                if b == Self.semicolon && newlines {
                    skipLine()
                } else if b == Self.space || b == Self.tab || b == Self.cr {
                    pos += 1
                } else if b == Self.lf && newlines {
                    pos += 1
                } else {
                    return
                }
            }
        }

        private func nextLineStartsWithComma() -> Bool {
            var i = pos + 1
            while i < data.count && (data[i] == Self.space || data[i] == Self.tab || data[i] == Self.cr) {
                i += 1
            }
            return i < data.count && data[i] == Self.comma
        }

        private func skipLine() {
            while pos < data.count && data[pos] != Self.lf {
                pos += 1
            }
        }

        private func indexOf(_ b: UInt8, from: Int) throws -> Int {
            var i = from
            while i < data.count {
                if data[i] == b {
                    return i
                }
                i += 1
            }
            throw ModelError("Unexpected end of FBX file.")
        }

        @inline(__always)
        private func isDigit(_ b: UInt8) -> Bool {
            b >= 0x30 && b <= 0x39
        }

        @inline(__always)
        private func isWhitespace(_ b: UInt8) -> Bool {
            b == Self.space || b == Self.tab || b == Self.cr || b == Self.lf
        }

        @inline(__always)
        private func isDelimiter(_ b: UInt8) -> Bool {
            isWhitespace(b) || b == Self.comma || b == Self.openBrace || b == Self.closeBrace
        }
    }
}
