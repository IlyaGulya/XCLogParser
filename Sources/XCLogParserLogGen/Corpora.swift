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

/// The text the generator draws on.
///
/// Small fixed corpora, not realistic variety: the profiles reproduce the *shape* of a build log, so
/// what matters here is that the strings carry the markers the parser looks for - `": warning:"`,
/// `": error:"` and `[-Wflag]`. Anything that depends on the variety of strings rather than on their
/// shape will differ from a real log, which `Benchmarks/Profiles/README.md` states outright.
extension LogBuilder {

    static let warningMessages = [
        "variable 'value' was never mutated; consider changing to 'let' constant",
        "result of call to 'compute' is unused",
        "'init(coder:)' is deprecated: use the designated initializer instead",
        "conditional cast from 'Any' to 'String' always succeeds",
        "immutable value 'error' was never used; consider replacing with '_'",
        "comparing non-optional value of type 'Int' to 'nil' always returns true",
        "no 'async' operations occur within 'await' expression",
        "capture of 'self' with non-sendable type in a '@Sendable' closure"
    ]

    /// Clang diagnostics, which read differently from Swift ones and pair with a `-Wflag`.
    static let clangMessages = [
        "unused variable 'value'",
        "'sharedInstance' is deprecated: first deprecated in iOS 13.0",
        "implicit conversion loses integer precision: 'long' to 'int'",
        "comparison of integers of different signs: 'int' and 'unsigned long'",
        "format specifies type 'id' but the argument has type 'NSInteger'",
        "incompatible pointer types initializing 'NSString *' with 'NSNumber *'"
    ]

    /// The flags written into clang section text as `[-Wflag]`, which is the pattern
    /// `parseClangWarningFlags` scans for. `-Wdeprecated-declarations` is included deliberately: it
    /// is what drives the `deprecatedWarning` reclassification.
    static let clangFlags = [
        "-Wunused-variable",
        "-Wdeprecated-declarations",
        "-Wshorten-64-to-32",
        "-Wsign-compare",
        "-Wformat",
        "-Wincompatible-pointer-types"
    ]

    /// Function signatures for `-debug-time-function-bodies` output.
    ///
    /// The shape matters more than the variety: `swiftc` writes the signature as the third
    /// tab-separated field, and it may contain spaces, colons and parentheses. A corpus of bare
    /// identifiers would leave the field-splitting untested against the punctuation real output has.
    static let functionSignatures = [
        "getter textLabel",
        "initializer init(frame:)",
        "closure #1 (Swift.Result<Foundation.Data, Swift.Error>) -> () in configure()",
        "static SomeModule.Factory.make(with:) -> SomeModule.Service",
        "protocol witness for Presenting.present(_:animated:) in conformance ViewController",
        "implicit closure #2 () throws -> Swift.Bool in validate(input:)",
        "deinit",
        "subscript.getter"
    ]

    static let fillerLines = [
        "    CompileSwift normal arm64 Compiling\\ File.swift",
        "    cd /project",
        "    /usr/bin/swiftc -module-name GeneratedApp -O -whole-module-optimization",
        "    export SDKROOT=/Applications/Xcode.app/Contents/Developer/SDKs/MacOSX.sdk",
        "    builtin-swiftTaskExecution -- swift-frontend -c -primary-file",
        "    Using response file for the frontend invocation",
        "    note: Building targets in dependency order"
    ]

    /// The filler corpus pre-measured, so the hot loop never recounts a line. Measuring it per line
    /// per section is what made generating a 265 MB log take 40 seconds instead of 2.5.
    static let fillerLineBytes: [[UInt8]] = fillerLines.map { Array($0.utf8) }
    static let fillerLineColons: [Int] = fillerLines.map { colonCount(in: $0) }
    static let colonSuffix: [UInt8] = Array(": ok\r".utf8)

    /// Counts `":"` bytes. Used both to pre-measure the corpus and to score generated text.
    static func colonCount(in text: String) -> Int {
        var count = 0
        for byte in text.utf8 where byte == UInt8(ascii: ":") { count += 1 }
        return count
    }
}
