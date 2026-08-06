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

/// A string the lexer has scanned but may not have built yet.
///
/// `Token.string` used to carry a `String`, which meant the lexer allocated one per string token
/// whether or not anything read it. On the baseline log 91% of all string-token bytes are section
/// text, and 93% of *that* belongs to sections whose `messages` is empty - where
/// `Notice.parseFromLogSection` returns before touching the text. Carrying a range into the log and
/// decoding on demand means those bytes are never copied.
///
/// The deferred form is only available when the lexer is not rewriting the string: `redacted` and
/// `withoutBuildSpecificInformation` transform the scanned bytes, so a range into the original log
/// would no longer describe the result. Under either flag the lexer materialises eagerly and this
/// holds a plain `String`.
public struct LazyString {
    private enum Storage {
        case materialized(String)
        case deferred(LogBytes, Range<Int>)
    }

    private var storage: Storage

    public init(_ value: String) {
        storage = .materialized(value)
    }

    init(bytes: LogBytes, range: Range<Int>) {
        storage = .deferred(bytes, range)
    }

    /// The string itself, decoded on first access.
    ///
    /// Not memoized: `Token` is a value type, so a cache written here would be discarded by the next
    /// copy. Callers that read a token's string more than once should bind it to a local - which is
    /// what the parser does, and what `IDEActivityLogSection.text` does across its several readers.
    public var value: String {
        switch storage {
        case .materialized(let value):
            return value
        case .deferred(let bytes, let range):
            return bytes.string(in: range)
        }
    }

    /// The log bytes and range behind a deferred string, or `nil` if it is already a `String`.
    ///
    /// Lets the parser hand a section's text straight to `IDEActivityLogSection` as a range, so it is
    /// not decoded on the way through.
    var deferredRange: (LogBytes, Range<Int>)? {
        switch storage {
        case .materialized:
            return nil
        case .deferred(let bytes, let range):
            return (bytes, range)
        }
    }
}

extension LazyString: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(value)
    }
}

extension LazyString: Equatable {
    /// Compares what the strings *are*, not how they are stored, so a deferred string equals the
    /// materialized one with the same contents. `Token`'s synthesised `==` relies on this.
    public static func == (lhs: LazyString, rhs: LazyString) -> Bool {
        return lhs.value == rhs.value
    }
}

extension LazyString: CustomStringConvertible {
    public var description: String { value }
}
