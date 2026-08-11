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

/// The per-`TokenType` scanning cases, split out of `Lexer` to keep that type under the length limit.
///
/// Order matters: `handleClassNameTokenTypeCase` appends to `classNames` and
/// `handleClassNameRefTokenTypeCase` indexes into it, so tokens must be produced in delimiter order.
extension Lexer {

    func handleIntTokenTypeCase(scanner: Scanner, payload: Range<Int>) -> Token? {
        guard let value = scanner.unsignedInteger(in: payload) else {
            print("error parsing int")
            return nil
        }
        return .int(value)
    }

    func handleClassNameTokenTypeCase(scanner: Scanner,
                                      payload: Range<Int>,
                                      redacted: Bool,
                                      withoutBuildSpecificInformation: Bool) -> Token? {
        guard let className = scanString(length: payload,
                                         scanner: scanner,
                                         redacted: redacted,
                                         withoutBuildSpecificInformation: withoutBuildSpecificInformation) else {
                                            print("error parsing string")
                                            return nil
        }
        classNames.append(className)
        return .className(className)
    }

    func handleClassNameRefTokenTypeCase(scanner: Scanner, payload: Range<Int>) -> Token? {
        guard let parsed = scanner.unsignedInteger(in: payload), let value = Int(exactly: parsed) else {
            print("error parsing classNameRef")
            return nil
        }
        // Bounds-checked because the index comes from the log, not from us. `classNames` is populated by
        // the `className` tokens seen so far, so a malformed document can reference an entry that does
        // not exist - a payload of `0` gives -1, and any index past the declarations is out of range.
        // Subscripting directly crashed the process with "Index out of range"; returning nil reports it
        // as an invalid line, which is how every other malformed payload here behaves. Found by
        // differential testing over generated SLF documents ("SLF01@356098f239dfc041^" is enough).
        let element = value - 1
        guard classNames.indices.contains(element) else {
            print("error parsing classNameRef: no class name at index \(value)")
            return nil
        }
        return .classNameRef(classNames[element])
    }

    func handleStringTokenTypeCase(scanner: Scanner,
                                   payload: Range<Int>,
                                   redacted: Bool,
                                   withoutBuildSpecificInformation: Bool) -> Token? {
        // The whole point of `LazyString`: skip the string entirely and carry the range. Only when the
        // log is retained (`tokenize(data:)`) and neither rewriting flag is on, since both change the
        // bytes and a range into the original would no longer describe the result.
        if let logBytes = logBytes, !redacted, !withoutBuildSpecificInformation {
            guard let range = scanStringRange(length: payload, scanner: scanner) else {
                print("error parsing string")
                return nil
            }
            return .string(LazyString(bytes: logBytes, range: range))
        }
        guard let content = scanString(length: payload,
                                       scanner: scanner,
                                       redacted: redacted,
                                       withoutBuildSpecificInformation: withoutBuildSpecificInformation) else {
                                        print("error parsing string")
                                        return nil
        }
        return .string(LazyString(content))
    }

    /// Consumes a length-prefixed string like `scanString`, but returns the byte range instead of
    /// decoding it.
    func scanStringRange(length: Range<Int>, scanner: Scanner) -> Range<Int>? {
        guard let parsed = scanner.unsignedInteger(in: length), let value = Int(exactly: parsed),
              let range = scanner.skip(count: value) else {
            return nil
        }
        return range
    }

    func handleJSONTokenTypeCase(scanner: Scanner,
                                 payload: Range<Int>,
                                 redacted: Bool,
                                 withoutBuildSpecificInformation: Bool) -> Token? {
        guard let content = scanString(length: payload,
                                       scanner: scanner,
                                       redacted: redacted,
                                       withoutBuildSpecificInformation: withoutBuildSpecificInformation) else {
                                        print("error parsing string")
                                        return nil
        }
        return .json(content)
    }

    func handleDoubleTokenTypeCase(scanner: Scanner, payload: Range<Int>) -> Token? {
        guard let bigEndianBits = scanner.unsignedInteger(in: payload, radix: 16) else {
            print("error parsing double")
            return nil
        }
        return .double(Double(bitPattern: bigEndianBits.byteSwapped))
    }

    func handleListTokenTypeCase(scanner: Scanner, payload: Range<Int>) -> Token? {
        guard let parsed = scanner.unsignedInteger(in: payload), let value = Int(exactly: parsed) else {
            print("error parsing list")
            return nil
        }
        return .list(value)
    }

    func scanString(length: Range<Int>,
                    scanner: Scanner,
                    redacted: Bool,
                    withoutBuildSpecificInformation: Bool) -> String? {
        guard let parsed = scanner.unsignedInteger(in: length), let value = Int(exactly: parsed),
              let scannedResult = scanner.scan(count: value) else {
            print("error parsing string")
            return nil
        }

        var result = scannedResult
        if redacted {
            result = redactor.redactUserDir(string: result)
        }
        if withoutBuildSpecificInformation {
            result = result
                .removeProductBuildIdentifier()
                .removeHexadecimalNumbers()
        }
        return result
    }

}
