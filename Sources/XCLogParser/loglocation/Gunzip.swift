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

/// Decompresses a gzipped log.
///
/// A named entry point for the one thing the read path does, so that a change to how the log is
/// inflated has a stable call site to be measured at. It delegates to GzipSwift, and the benchmark's
/// gunzip stage times this function.
public enum Gunzip {

    /// Inflates a gzipped log.
    ///
    /// - parameter data: The gzipped bytes.
    /// - returns: The decompressed log.
    /// - throws: Whatever the underlying inflate throws on malformed input.
    public static func inflate(_ data: Data) throws -> Data {
        return try data.gunzipped()
    }
}
