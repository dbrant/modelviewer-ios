//
//  FbxNode.swift
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

/// A property of an FBX node.
///
/// Properties of binary files are numbers (Short, Int, Long, Float, Double, or Boolean), strings,
/// byte arrays, or arrays of numbers. In ASCII files, the properties of a node that are all
/// numbers are read as a single array of Longs (if they're all integers) or of Doubles, and other
/// properties as Longs, Doubles, and Strings.
enum FbxValue {
    case short(Int16)
    case int(Int32)
    case long(Int64)
    case float(Float)
    case double(Double)
    case bool(Bool)
    case string(String)
    case bytes(Data)
    case floats([Float])
    case doubles([Double])
    case longs([Int64])
    case ints([Int32])
    case bools([Bool])

    /// The value as a number, if it's a single number (not a Boolean).
    var scalarNumber: Double? {
        switch self {
        case .short(let v): Double(v)
        case .int(let v): Double(v)
        case .long(let v): Double(v)
        case .float(let v): Double(v)
        case .double(let v): v
        default: nil
        }
    }
}

/// A node of an FBX document, with its name, properties, and child nodes.
final class FbxNode {
    let name: String
    let properties: [FbxValue]
    let children: [FbxNode]

    init(name: String, properties: [FbxValue], children: [FbxNode]) {
        self.name = name
        self.properties = properties
        self.children = children
    }

    func child(_ name: String) -> FbxNode? {
        children.first { $0.name == name }
    }

    func children(_ name: String) -> [FbxNode] {
        children.filter { $0.name == name }
    }

    func string(_ index: Int) -> String? {
        guard index >= 0 && index < properties.count, case .string(let s) = properties[index] else {
            return nil
        }
        return s
    }

    /// The property at the given index as a number, or nil if it isn't one.
    func number(_ index: Int) -> Double? {
        if properties.count == 1 {
            switch properties[0] {
            case .longs, .doubles:
                let numbers = numbers()
                return index >= 0 && index < numbers.count ? numbers[index] : nil
            default:
                break
            }
        }
        guard index >= 0 && index < properties.count else {
            return nil
        }
        if case .bool(let b) = properties[index] {
            return b ? 1 : 0
        }
        return properties[index].scalarNumber
    }

    /// The property at the given index as an ID (64-bit integer), or nil if it isn't one.
    func id(_ index: Int) -> Int64? {
        if properties.count == 1, case .longs(let values) = properties[0] {
            return index >= 0 && index < values.count ? values[index] : nil
        }
        guard index >= 0 && index < properties.count else {
            return nil
        }
        switch properties[index] {
        case .long(let v): return v
        case .int(let v): return Int64(v)
        case .double(let v): return FbxNode.toInt64(v)
        default: return nil
        }
    }

    /// All of the numbers of the node: the elements of an array property, or the properties
    /// themselves, or (in ASCII files of version 7 and above) those of the node's "a" child.
    func numbers() -> [Double] {
        if let a = child("a") {
            return a.numbers()
        }
        if properties.count == 1 {
            switch properties[0] {
            case .doubles(let v): return v
            case .floats(let v): return v.map { Double($0) }
            case .ints(let v): return v.map { Double($0) }
            case .longs(let v): return v.map { Double($0) }
            case .bools(let v): return v.map { $0 ? 1 : 0 }
            default: break
            }
        }
        return properties.compactMap { $0.scalarNumber }
    }

    /// All of the numbers of the node, as integers.
    func ints() -> [Int] {
        if let a = child("a") {
            return a.ints()
        }
        if properties.count == 1 {
            switch properties[0] {
            case .ints(let v): return v.map { Int($0) }
            case .longs(let v): return v.map { Int(Int32(truncatingIfNeeded: $0)) }
            default: break
            }
        }
        return numbers().map { FbxNode.toInt32($0) }
    }

    /// Converts a Double to an integer as Kotlin's Double.toInt() does: NaN is 0, and others are clamped to 32 bits.
    static func toInt32(_ value: Double) -> Int {
        if value.isNaN { return 0 }
        if value >= Double(Int32.max) { return Int(Int32.max) }
        if value <= Double(Int32.min) { return Int(Int32.min) }
        return Int(value)
    }

    static func toInt64(_ value: Double) -> Int64 {
        if value.isNaN { return 0 }
        if value >= 9.2e18 { return Int64.max }
        if value <= -9.2e18 { return Int64.min }
        return Int64(value)
    }
}
