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

/// One `file://`-prefixed `String` per distinct path, reused for every timing option that names it.
///
/// A build with `-debug-time-function-bodies` reports one timing per function body, so a flagged fleet
/// log yields around 450,000 options naming around 24,000 distinct files - roughly nineteen options per
/// file. Each option stores the file it belongs to, and building that string per option meant the same
/// path existed as nineteen separate allocations on average.
///
/// Handing every option the *same* instance makes them share storage instead: `String` is copy-on-write
/// and nothing here mutates it, so the copies are pointer copies. That is worth more than the lookup
/// costs, because the alternative allocates and then keeps the result for the life of the report.
///
/// Not a general-purpose intern table. It is deliberately unsynchronised and owned by one
/// `SwiftCompilerParser`, so it is only ever touched from whichever thread is running that parse.
final class FileURLCache {

    /// Keyed by the raw path bytes rather than a `String`, so a lookup that hits does not have to build
    /// the string it is trying to avoid building.
    private var urls: [ArraySlice<UInt8>: String] = [:]

    /// The `file://`-prefixed form of `pathBytes`, or `nil` if the path is one to discard.
    ///
    /// Returns `nil` for `<invalid loc>`, which `swiftc` emits for a function whose source location it
    /// does not know. Callers drop the whole line, which is what the string-based parser did.
    func url(forPathBytes pathBytes: String.UTF8View.SubSequence) -> String? {
        // `ArraySlice` rather than the view's own slice type: the key has to outlive the text it came
        // from, and it has to hash by content. One copy of the path bytes per *distinct* path is the
        // cost of not copying the whole string per *option*.
        let key = ArraySlice(pathBytes)
        if let cached = urls[key] {
            return cached
        }
        // swiftlint:disable:next optional_data_string_conversion
        let path = String(decoding: pathBytes, as: UTF8.self)
        guard path != Self.invalidLocation else {
            return nil
        }
        let url = "file://\(path)"
        urls[key] = url
        return url
    }

    private static let invalidLocation = "<invalid loc>"
}
