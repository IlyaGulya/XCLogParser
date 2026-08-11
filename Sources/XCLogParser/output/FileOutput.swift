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
import PathKit

public final class FileOutput: ReporterOutput {

    let path: String

    /// Open only for the duration of a streamed write. See `beginStreaming()`.
    private var streamHandle: FileHandle?

    public init(path: String) {
        let absolutePath = Path(path).absolute()
        self.path = absolutePath.string
    }

    public func write(report: Any) throws {
        switch report {
        case let data as Data:
            try write(data: data)
        case let tokens as [Token]:
            try write(tokens: tokens)
        default:
            throw XCLogParserError.errorCreatingReport("Can't write the report. Type not supported: " +
                                                       "\(type(of: report)).")
        }
    }

    private func write(data: Data) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path) {
            throw XCLogParserError.errorCreatingReport("Can't write the report to \(path). A file already exists.")
        }
        let url = URL(fileURLWithPath: path)
        try data.write(to: url)
        print("File written to \(path)")
    }

    private func write(tokens: [Token]) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) == false
             else {
            throw XCLogParserError.errorCreatingReport("Can't write the report to \(path). A file already exists.")
        }
        fileManager.createFile(atPath: path, contents: nil, attributes: nil)
        guard let fileHandle = FileHandle.init(forWritingAtPath: path) else {
            throw XCLogParserError.errorCreatingReport("Can't write the report to \(path). File can't be created.")
        }
        defer {
            fileHandle.closeFile()
        }
        for token in tokens {
            guard let data = "\(token)\n".data(using: .utf8) else {
                throw XCLogParserError.errorCreatingReport("Can't write the report to \(path)." +
                                                            "Token can't be serialized \(token).")
            }
            fileHandle.write(data)
        }
        print("File written to \(path)")
    }

}

extension FileOutput: StreamingReporterOutput {

    /// Creates the file and opens it for appending.
    ///
    /// The "a file already exists" check happens here, which is the same point in the sequence as in
    /// `write(data:)`: before any byte of the report is emitted. Ordering it any later would leave a
    /// truncated file behind on a path that used to fail cleanly.
    public func beginStreaming() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path) {
            throw XCLogParserError.errorCreatingReport("Can't write the report to \(path). A file already exists.")
        }
        guard fileManager.createFile(atPath: path, contents: nil, attributes: nil),
              let handle = FileHandle(forWritingAtPath: path) else {
            throw XCLogParserError.errorCreatingReport("Can't write the report to \(path). File can't be created.")
        }
        streamHandle = handle
    }

    public func write(chunk: Data) throws {
        guard let handle = streamHandle else {
            throw XCLogParserError.errorCreatingReport("Can't write the report to \(path). Stream is not open.")
        }
        handle.write(chunk)
    }

    public func endStreaming() throws {
        streamHandle?.closeFile()
        streamHandle = nil
        print("File written to \(path)")
    }

}
