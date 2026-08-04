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

public final class StandardOutput: ReporterOutput {

    public init() {}

    public func write(report: Any) throws {
        switch report {
        case let tokens as [Token]:
            tokens.forEach { (token) in
                print(token)
            }
        case let data as Data:
            write(data: data)
        default:
            print("Type not supported \(type(of: report))")
        }

    }

    /// Writes the report's bytes straight to stdout.
    ///
    /// This used to go through `String(data: data, encoding: .utf8)` and `print`, which for a report
    /// meant validating 94-171 MB as UTF-8 and copying all of it into a second String of the same
    /// size. That was 25% of the time inside this function - about 4% of the whole run - plus a
    /// transient buffer as large as the report itself.
    ///
    /// Writing the `Data` produces the same bytes: `print(string)` emits the UTF-8 encoding of a
    /// String that was built by validating these exact bytes, followed by a newline. The one
    /// behavioural difference is invalid UTF-8, where the old code printed *nothing at all* because
    /// the optional initializer returned nil - so bytes now reach stdout in a case that previously
    /// produced silence.
    private func write(data: Data) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

}

extension StandardOutput: StreamingReporterOutput {

    /// Nothing to open: stdout is already there, and `write(data:)` above writes to it directly. The
    /// streamed path therefore emits byte for byte what the single-call path emits - the chunks
    /// concatenated, then the same trailing newline.
    public func beginStreaming() throws {}

    public func write(chunk: Data) throws {
        FileHandle.standardOutput.write(chunk)
    }

    public func endStreaming() throws {
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

}
