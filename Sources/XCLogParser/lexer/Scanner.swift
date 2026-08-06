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

final class Scanner {

    let string: String
    private let bytes: [UInt8]

    private(set) var offset: Int

    /// How many bytes there are to scan.
    ///
    /// Exposed so `Lexer.tokenize` can size its token array from the input without knowing how the
    /// scanner stores it - the input arrives as a `String`, an `[UInt8]` or a `Data` depending on the
    /// entry point, and the loop is shared.
    var byteCount: Int {
        bytes.count
    }

    var isAtEnd: Bool {
        offset >= bytes.count
    }

    init(string: String) {
        self.string = string
        self.bytes = Array(string.utf8)
        self.offset = 0
    }

    func scan(count: Int) -> String? {
        let endOffset = self.offset + count

        guard count >= 0,
              endOffset <= bytes.count,
              let result = String(bytes: bytes[offset..<endOffset], encoding: .utf8)
        else { return nil }

        self.offset += count

        return result
    }

    func scan(string value: String) -> Bool {
        let valueBytes = Array(value.utf8)
        let endOffset = offset + valueBytes.count
        guard endOffset <= bytes.count,
              bytes[offset..<endOffset].elementsEqual(valueBytes)
        else { return false }

        self.offset += valueBytes.count
        return true
    }

    func scanCharacters(from allowedCharacters: Set<Character>) -> String? {
        let allowedBytes = Set(
            allowedCharacters.compactMap { character -> UInt8? in
                let characterBytes = Array(String(character).utf8)
                return characterBytes.count == 1 ? characterBytes[0] : nil
            }
        )
        var prefix: [UInt8] = []

        while !isAtEnd {
            guard allowedBytes.contains(bytes[offset]) else {
                break
            }

            prefix.append(bytes[offset])
            self.offset += 1
        }

        return String(bytes: prefix, encoding: .utf8)
    }

    func moveOffset(by value: Int) {
        self.offset += value
    }

    func preview(count: Int) -> String {
        let endOffset = min(offset + count, bytes.count)
        return String(decoding: bytes[offset..<endOffset], as: UTF8.self)
    }
}
