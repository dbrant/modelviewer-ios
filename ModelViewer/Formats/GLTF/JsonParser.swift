//
//  JsonParser.swift
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

/// A JSON value. Numbers are always Doubles, so they're never confused with booleans.
enum JsonValue: Sendable {
    case object([String: JsonValue])
    case array([JsonValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    var objectValue: [String: JsonValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [JsonValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    /// The number as an Int, converted as Kotlin's Double.toInt() does (truncated, and clamped to 32 bits).
    var intValue: Int? {
        numberValue.map { JsonParser.toInt($0) }
    }
}

/// A minimal JSON parser, which works on UTF-8 bytes.
struct JsonParser {
    private static let maxDepth = 256

    private let bytes: [UInt8]
    private var pos = 0

    private init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    static func parse(_ data: Data) throws -> JsonValue {
        var bytes = [UInt8](data)
        // Skip a byte order mark.
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            bytes.removeFirst(3)
        }
        var parser = JsonParser(bytes)
        let value = try parser.readValue(0)
        parser.skipWhitespace()
        if parser.pos != bytes.count {
            throw ModelError("Invalid JSON at position \(parser.pos).")
        }
        return value
    }

    /// Converts a Double to an Int as Kotlin's Double.toInt() does: truncated, clamped to 32 bits, and NaN is 0.
    static func toInt(_ d: Double) -> Int {
        if d.isNaN { return 0 }
        if d >= Double(Int32.max) { return Int(Int32.max) }
        if d <= Double(Int32.min) { return Int(Int32.min) }
        return Int(d)
    }

    private mutating func readValue(_ depth: Int) throws -> JsonValue {
        if depth > Self.maxDepth {
            throw ModelError("JSON is nested too deeply.")
        }
        skipWhitespace()
        if pos >= bytes.count {
            throw ModelError("Unexpected end of JSON.")
        }
        let c = bytes[pos]
        switch c {
        case UInt8(ascii: "{"):
            return try readObject(depth)
        case UInt8(ascii: "["):
            return try readArray(depth)
        case UInt8(ascii: "\""):
            return .string(try readString())
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return .number(try readNumber())
        default:
            if startsWith("true") {
                pos += 4
                return .bool(true)
            } else if startsWith("false") {
                pos += 5
                return .bool(false)
            } else if startsWith("null") {
                pos += 4
                return .null
            }
            throw ModelError("Invalid JSON at position \(pos).")
        }
    }

    private func startsWith(_ word: StaticString) -> Bool {
        let count = word.utf8CodeUnitCount
        if pos + count > bytes.count {
            return false
        }
        return word.withUTF8Buffer { w in
            for k in 0..<count where bytes[pos + k] != w[k] {
                return false
            }
            return true
        }
    }

    private mutating func readObject(_ depth: Int) throws -> JsonValue {
        var result: [String: JsonValue] = [:]
        pos += 1
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
            pos += 1
            return .object(result)
        }
        while true {
            skipWhitespace()
            if peek() != UInt8(ascii: "\"") {
                throw ModelError("Invalid JSON object at position \(pos).")
            }
            let key = try readString()
            skipWhitespace()
            try expect(UInt8(ascii: ":"))
            result[key] = try readValue(depth + 1)
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ","):
                pos += 1
            case UInt8(ascii: "}"):
                pos += 1
                return .object(result)
            default:
                throw ModelError("Invalid JSON object at position \(pos).")
            }
        }
    }

    private mutating func readArray(_ depth: Int) throws -> JsonValue {
        var result: [JsonValue] = []
        pos += 1
        skipWhitespace()
        if peek() == UInt8(ascii: "]") {
            pos += 1
            return .array(result)
        }
        while true {
            result.append(try readValue(depth + 1))
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ","):
                pos += 1
            case UInt8(ascii: "]"):
                pos += 1
                return .array(result)
            default:
                throw ModelError("Invalid JSON array at position \(pos).")
            }
        }
    }

    private mutating func readString() throws -> String {
        pos += 1
        let start = pos
        // Fast path: a string without escapes.
        while pos < bytes.count {
            let c = bytes[pos]
            if c == UInt8(ascii: "\"") {
                let s = String(decoding: bytes[start..<pos], as: UTF8.self)
                pos += 1
                return s
            }
            if c == UInt8(ascii: "\\") {
                break
            }
            pos += 1
        }
        var output = [UInt8](bytes[start..<pos])
        var pendingHighSurrogate: UInt32?
        while true {
            if pos >= bytes.count {
                throw ModelError("Unexpected end of JSON string.")
            }
            let c = bytes[pos]
            pos += 1
            if c == UInt8(ascii: "\\") {
                if pos >= bytes.count {
                    throw ModelError("Unexpected end of JSON string.")
                }
                let escaped = bytes[pos]
                pos += 1
                if escaped == UInt8(ascii: "u") {
                    guard pos + 4 <= bytes.count,
                          let code = UInt32(String(decoding: bytes[pos..<(pos + 4)], as: UTF8.self), radix: 16) else {
                        throw ModelError("Invalid JSON escape at position \(pos).")
                    }
                    pos += 4
                    if code >= 0xD800 && code < 0xDC00 {
                        if let high = pendingHighSurrogate {
                            appendScalar(high, to: &output)
                        }
                        pendingHighSurrogate = code
                        continue
                    }
                    if code >= 0xDC00 && code < 0xE000, let high = pendingHighSurrogate {
                        pendingHighSurrogate = nil
                        appendScalar(0x10000 + ((high - 0xD800) << 10) + (code - 0xDC00), to: &output)
                        continue
                    }
                    flushSurrogate(&pendingHighSurrogate, &output)
                    appendScalar(code, to: &output)
                    continue
                }
                flushSurrogate(&pendingHighSurrogate, &output)
                switch escaped {
                case UInt8(ascii: "b"): output.append(0x08)
                case UInt8(ascii: "f"): output.append(0x0C)
                case UInt8(ascii: "n"): output.append(0x0A)
                case UInt8(ascii: "r"): output.append(0x0D)
                case UInt8(ascii: "t"): output.append(0x09)
                default: output.append(escaped)
                }
            } else {
                flushSurrogate(&pendingHighSurrogate, &output)
                if c == UInt8(ascii: "\"") {
                    return String(decoding: output, as: UTF8.self)
                }
                output.append(c)
            }
        }
    }

    private func flushSurrogate(_ pending: inout UInt32?, _ output: inout [UInt8]) {
        if let high = pending {
            appendScalar(high, to: &output)
            pending = nil
        }
    }

    /// Appends a code point as UTF-8 (unpaired surrogates become the replacement character).
    private func appendScalar(_ code: UInt32, to output: inout [UInt8]) {
        let scalar = Unicode.Scalar(code) ?? Unicode.Scalar(0xFFFD)!
        output.append(contentsOf: Array(String(Character(scalar)).utf8))
    }

    private mutating func readNumber() throws -> Double {
        let start = pos
        while pos < bytes.count {
            let c = bytes[pos]
            if (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) || c == UInt8(ascii: "+") || c == UInt8(ascii: "-") ||
                c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
                pos += 1
            } else {
                break
            }
        }
        guard let value = TextScanner.parseDouble(bytes, start..<pos) else {
            throw ModelError("Invalid JSON number at position \(start).")
        }
        return value
    }

    private mutating func skipWhitespace() {
        while pos < bytes.count {
            let c = bytes[pos]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                pos += 1
            } else {
                break
            }
        }
    }

    private func peek() -> UInt8 {
        pos < bytes.count ? bytes[pos] : 0
    }

    private mutating func expect(_ c: UInt8) throws {
        if peek() != c {
            throw ModelError("Expected '\(Character(Unicode.Scalar(c)))' in JSON at position \(pos).")
        }
        pos += 1
    }
}
