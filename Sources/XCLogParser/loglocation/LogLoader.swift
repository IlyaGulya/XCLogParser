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
    /// The read path for parsing, and the one the benchmark harness times. `loadFromURL` decodes the
    /// decompressed bytes into a `String` which the lexer converts straight back to bytes; returning the
    /// `Data` lets later commits in this branch delete that round trip without moving the call site the
    /// measurements are taken at.
    ///
    /// # Behaviour on malformed input
    ///
    /// `loadFromURL` validates UTF-8 up front and throws `LogError.readingFile` for the whole log if any
    /// byte is invalid. This does not, because it does not decode - invalid bytes reach the lexer, which
    /// substitutes U+FFFD. That only affects logs Xcode never produces: the SLF structure is ASCII.
    /// Callers needing the strict behaviour should keep using `loadFromURL`.
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
