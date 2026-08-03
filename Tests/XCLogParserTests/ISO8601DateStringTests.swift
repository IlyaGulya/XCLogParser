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

import XCTest
@testable import XCLogParser

class ISO8601DateStringTests: XCTestCase {

    /// The format `ParserBuildSteps.dateFormatter` is configured with.
    private lazy var referenceFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(abbreviation: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ"
        return formatter
    }()

    private func format(_ interval: Double) -> String {
        return ISO8601DateString.format(timeIntervalSinceReferenceDate: interval)
    }

    func testReferenceEpoch() {
        XCTAssertEqual(format(0), "2001-01-01T00:00:00.000000Z")
    }

    func testKnownTimestamp() {
        // A real section timestamp from an Xcode log.
        XCTAssertEqual(format(805375993.7705), "2026-07-10T11:33:13.771000Z")
    }

    /// `ZZZZZ` renders UTC as "Z", and `SSSSSS` is milliseconds zero-extended
    /// rather than microseconds.
    func testFractionIsMillisecondsZeroExtended() {
        XCTAssertEqual(format(0.1234564), "2001-01-01T00:00:00.123000Z")
        XCTAssertTrue(format(0.5).hasSuffix("Z"))
        XCTAssertFalse(format(0.5).contains("+00:00"))
    }

    /// Rounding up from .9995 must carry into the seconds field.
    func testFractionCarriesIntoSeconds() {
        XCTAssertEqual(format(0.9999994), "2001-01-01T00:00:01.000000Z")
    }

    /// Dates before the reference epoch use a negative interval; the time of day
    /// must stay non-negative and borrow a day.
    func testNegativeInterval() {
        XCTAssertEqual(format(-1), "2000-12-31T23:59:59.000000Z")
        XCTAssertEqual(referenceFormatter.string(from: Date(timeIntervalSinceReferenceDate: -1)),
                       format(-1))
    }

    func testLeapDay() {
        // 2004-02-29, a leap day in a leap year that is not a century.
        XCTAssertEqual(format(Double(1154) * 86_400), "2004-02-29T00:00:00.000000Z")
        // 2000-02-29: divisible by 400, so a leap year despite being a century.
        XCTAssertEqual(format(Double(-307) * 86_400), "2000-02-29T00:00:00.000000Z")
        // 1900-02-28: divisible by 100 but not 400, so 1900 is *not* a leap year.
        XCTAssertEqual(format(Double(-36_832) * 86_400), "1900-02-28T00:00:00.000000Z")
        // ...so the next day is March 1st, not February 29th.
        XCTAssertEqual(format(Double(-36_831) * 86_400), "1900-03-01T00:00:00.000000Z")
    }

    /// Agreement with `DateFormatter` across whole days spanning 1900-2100, which
    /// is what validates the civil-date arithmetic.
    func testMatchesDateFormatterAcrossCentury() {
        for day in stride(from: -36_800, through: 36_500, by: 7) {
            let interval = Double(day) * 86_400 + 45_296
            XCTAssertEqual(format(interval),
                           referenceFormatter.string(from: Date(timeIntervalSinceReferenceDate: interval)),
                           "disagreed at day offset \(day)")
        }
    }

    /// Documents the one accepted divergence: at an exact half-millisecond tie
    /// this rounds up where `DateFormatter` rounds down, a 1ms difference on
    /// 0.011% of real dates. If this test starts failing, the rounding rule
    /// changed - read the type's doc comment before "fixing" it.
    func testHalfMillisecondTieDivergesFromDateFormatter() {
        let tie = 805375090.6235
        XCTAssertEqual(format(tie), "2026-07-10T11:18:10.624000Z")
        XCTAssertEqual(referenceFormatter.string(from: Date(timeIntervalSinceReferenceDate: tie)),
                       "2026-07-10T11:18:10.623000Z")
    }

    /// Most half-millisecond values do *not* diverge - the microsecond-scaling
    /// rule handles them - which is why the divergence is 0.011% and not 100%.
    func testTypicalFourDecimalTimestampAgrees() {
        let value = 805375056.6135
        XCTAssertEqual(format(value),
                       referenceFormatter.string(from: Date(timeIntervalSinceReferenceDate: value)))
    }
}
