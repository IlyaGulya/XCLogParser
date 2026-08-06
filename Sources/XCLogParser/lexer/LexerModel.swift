// Copyright (c) 2019 Spotify AB.
//
// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import Foundation

public enum TokenType: String, CaseIterable {
    case int = "#"
    case className = "%"
    case classNameRef = "@"
    case string = "\""
    case double = "^"
    case null = "-"
    case list = "("
    case json = "*"

    static func all() -> String {
        return TokenType.allCases.reduce(String()) {
            return "\($0)\($1.rawValue)"
        }
    }

    /// Looks up a token type from its delimiter byte, without building a `String`.
    ///
    /// The lexer used to call `TokenType(rawValue: String(UnicodeScalar(byte)))` once per token -
    /// ~2.13M times on a large log - which allocates a single-character String and then runs the
    /// synthesized raw-value lookup as a sequence of full Unicode string comparisons. That measured
    /// as 2.0% (flagged) / 3.2% (baseline) of samples.
    ///
    /// A byte switch is the same mapping: every raw value above is one ASCII character, so comparing
    /// the byte is equivalent to comparing the one-character String it would have been wrapped in.
    /// Kept next to the cases so the two cannot drift apart unnoticed.
    init?(byte: UInt8) {
        switch byte {
        case UInt8(ascii: "#"): self = .int
        case UInt8(ascii: "%"): self = .className
        case UInt8(ascii: "@"): self = .classNameRef
        case UInt8(ascii: "\""): self = .string
        case UInt8(ascii: "^"): self = .double
        case UInt8(ascii: "-"): self = .null
        case UInt8(ascii: "("): self = .list
        case UInt8(ascii: "*"): self = .json
        default: return nil
        }
    }
}

public enum Token: CustomDebugStringConvertible, Equatable {
    case int(UInt64)
    case className(String)
    case classNameRef(String)
    /// A string that may not have been decoded yet - see `LazyString`. Read `.value` for the string.
    case string(LazyString)
    case double(Double)
    case null
    case list(Int)
    case json(String)
}

extension Token {
    public var debugDescription: String {
        switch self {
        case .int(let value):
            return "[type: int, value: \(value)]"
        case .className(let name):
            return "[type: className, name: \"\(name)\"]"
        case .classNameRef(let name):
            return "[type: classNameRef, className: \"\(name)\"]"
        case .string(let value):
            return "[type: string, value: \"\(value)\"]"
        case .double(let value):
            return "[type: double, value: \(value)]"
        case .null:
            return "[type: nil]"
        case .list(let count):
            return "[type: list, count: \(count)]"
        case .json(let json):
            return "[type: json, value: \(json)]"
        }
    }
}
