//
//  TextScanner.swift
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

/// Fast line-by-line scanning of ASCII text (as in STL, OBJ, and PLY files), which works on the
/// bytes of the text, without converting all of it to Strings.
struct TextScanner {
    let bytes: [UInt8]
    private(set) var position: Int

    init(_ data: Data, position: Int = 0) {
        self.bytes = [UInt8](data)
        self.position = position
    }

    init(bytes: [UInt8], position: Int = 0) {
        self.bytes = bytes
        self.position = position
    }

    var isAtEnd: Bool { position >= bytes.count }

    /// Returns the range of the next line (without its line terminator), or nil at the end of the text.
    mutating func nextLine() -> Range<Int>? {
        if position >= bytes.count {
            return nil
        }
        let start = position
        var end = start
        let n = bytes.count
        while end < n && bytes[end] != 0x0A && bytes[end] != 0x0D {
            end += 1
        }
        position = end
        if position < n && bytes[position] == 0x0D {
            position += 1
        }
        if position < n && bytes[position] == 0x0A {
            position += 1
        }
        return start..<end
    }

    /// Splits a range of the text into whitespace-separated tokens.
    func tokens(in range: Range<Int>) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
            while i < end && Self.isSpace(bytes[i]) { i += 1 }
            if i >= end { break }
            let start = i
            while i < end && !Self.isSpace(bytes[i]) { i += 1 }
            result.append(start..<i)
        }
        return result
    }

    /// The range without leading and trailing whitespace.
    func trimmed(_ range: Range<Int>) -> Range<Int> {
        var start = range.lowerBound
        var end = range.upperBound
        while start < end && Self.isSpace(bytes[start]) { start += 1 }
        while end > start && Self.isSpace(bytes[end - 1]) { end -= 1 }
        return start..<end
    }

    func string(_ range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
    }

    /// Whether the range starts with the given ASCII text.
    func hasPrefix(_ range: Range<Int>, _ prefix: StaticString) -> Bool {
        let count = prefix.utf8CodeUnitCount
        if range.count < count {
            return false
        }
        return prefix.withUTF8Buffer { p in
            for k in 0..<count where bytes[range.lowerBound + k] != p[k] {
                return false
            }
            return true
        }
    }

    /// Whether the range is exactly the given ASCII text.
    func equals(_ range: Range<Int>, _ text: StaticString) -> Bool {
        range.count == text.utf8CodeUnitCount && hasPrefix(range, text)
    }

    func double(_ range: Range<Int>) -> Double? {
        Self.parseDouble(bytes, range)
    }

    func float(_ range: Range<Int>) -> Float? {
        Self.parseDouble(bytes, range).map { Float($0) }
    }

    func int(_ range: Range<Int>) -> Int? {
        Self.parseInt(bytes, range)
    }

    @inline(__always)
    static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0B || b == 0x0C
    }

    /// Parses a decimal integer, with an optional sign. Returns nil if there are no digits, or any other characters.
    static func parseInt(_ bytes: [UInt8], _ range: Range<Int>) -> Int? {
        var i = range.lowerBound
        let end = range.upperBound
        if i >= end { return nil }
        var negative = false
        if bytes[i] == 0x2D || bytes[i] == 0x2B {
            negative = bytes[i] == 0x2D
            i += 1
        }
        if i >= end { return nil }
        var value = 0
        while i < end {
            let d = Int(bytes[i]) - 0x30
            if d < 0 || d > 9 { return nil }
            value = value &* 10 &+ d
            i += 1
        }
        return negative ? -value : value
    }

    /// Parses a floating-point number (as with strtod, which accepts "nan" and "inf" too).
    /// Returns nil if the whole range isn't a number.
    static func parseDouble(_ bytes: [UInt8], _ range: Range<Int>) -> Double? {
        let count = range.count
        if count == 0 || count > 63 {
            if count > 63 {
                return Double(String(decoding: bytes[range], as: UTF8.self))
            }
            return nil
        }
        // Fast path for plain decimals (digits, with an optional sign and point), which are most numbers in model files.
        var i = range.lowerBound
        let end = range.upperBound
        var negative = false
        if bytes[i] == 0x2D || bytes[i] == 0x2B {
            negative = bytes[i] == 0x2D
            i += 1
        }
        var mantissa: UInt64 = 0
        var digits = 0
        var fractionDigits = 0
        var seenPoint = false
        var simple = i < end
        while i < end {
            let b = bytes[i]
            if b >= 0x30 && b <= 0x39 {
                if digits >= 18 { simple = false; break }
                mantissa = mantissa * 10 + UInt64(b - 0x30)
                digits += 1
                if seenPoint { fractionDigits += 1 }
            } else if b == 0x2E && !seenPoint {
                seenPoint = true
            } else {
                simple = false
                break
            }
            i += 1
        }
        if simple && digits > 0 {
            var value = Double(mantissa)
            if fractionDigits > 0 {
                value /= powersOfTen[fractionDigits]
            }
            return negative ? -value : value
        }
        // Anything else (exponents, etc.) is parsed with strtod.
        return withUnsafeTemporaryAllocation(of: CChar.self, capacity: 64) { buffer in
            for k in 0..<count {
                buffer[k] = CChar(bitPattern: bytes[range.lowerBound + k])
            }
            buffer[count] = 0
            var endPointer: UnsafeMutablePointer<CChar>?
            let value = strtod(buffer.baseAddress!, &endPointer)
            guard let endPointer, endPointer - buffer.baseAddress! == count else {
                return nil
            }
            return value
        }
    }

    private static let powersOfTen: [Double] = (0...18).map { pow(10, Double($0)) }
}
