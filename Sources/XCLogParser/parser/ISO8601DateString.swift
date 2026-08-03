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

/// Formats a reference-epoch time interval as `yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ`
/// in UTC, without `DateFormatter`.
///
/// `ParserBuildSteps` calls this twice per log section (`startDate` and
/// `endDate`). Going through `DateFormatter` meant ICU date-field formatting plus
/// Objective-C bridging on every one of those calls: DTrace time profiling
/// attributed a significant share of all samples in a full parse to `NSDateFormatter`, the
/// single largest item inside `parseLogSection`.
///
/// The cost was avoidable because nothing about the formatter varied. The format
/// string is a literal, the locale is `en_US_POSIX` and the time zone is UTC, so
/// every field is fixed-width and locale-independent, and the whole result is
/// computable with integer arithmetic.
///
/// # What was tried and rejected
///
/// - **Caching by timestamp.** Section timestamps are almost all distinct, so a
///   cache would hold one entry per section and never hit.
/// - **`ISO8601DateFormatter`.** Same ICU machinery underneath, and it cannot
///   emit 6 fractional digits.
/// - **Reusing the formatter instance.** It was already a `lazy var`, so the
///   cost was steady-state formatting, not setup.
///
/// # Matching `DateFormatter`'s output
///
/// These strings go into reporter JSON, so the format was reproduced field by
/// field. Two fields are not what the format string suggests:
///
/// - `SSSSSS` does **not** give microsecond resolution. `DateFormatter` computes
///   *milliseconds*, rounds them to the nearest integer, and zero-pads to the
///   requested width. So `0.1234564` formats as `.123000`, and `0.9999994`
///   rounds up to `.000000` while carrying a second. Truncating to 6 digits
///   instead - the obvious reading of the format string - disagrees on almost
///   every input with a fractional part; a differential sweep caught it.
/// - `ZZZZZ` in UTC renders as the literal `"Z"`, not `"+00:00"`.
///
/// Verified by differential sweep: 152,512 synthetic values (reference epoch,
/// leap days, year boundaries, negative intervals, fractional stress) and 223,938
/// section dates from two real logs.
///
/// # Known difference: exact half-millisecond ties
///
/// **This is not byte-identical to `DateFormatter` in all cases.** On the real
/// logs it differed on 24 of 223,938 dates (0.011%), always by exactly 1ms, and
/// only where the fractional part lands exactly on a half millisecond. Xcode
/// writes timestamps with 4 decimal places, so such ties are common rather than
/// theoretical - e.g. `805375090.6235`, where this type rounds the tie up to
/// `.624000` and `DateFormatter` rounds it down to `.623000`.
///
/// Reproducing ICU exactly at a tie was attempted and abandoned. These
/// hypotheses were each falsified by measurement:
///
/// - Rounding the binary double half-up or half-even.
/// - Snapping the fraction to a fixed decimal precision (tried 4 through 7)
///   before rounding.
/// - Rounding the shortest round-trip decimal representation half-up.
///
/// The decisive counterexample: `676.49996...` rounds *down* to 676 while
/// `613.49999...` rounds *up* to 614. Same shape, opposite direction, and the
/// result is stable across the magnitude of the whole-seconds part, so it is not
/// precision loss in the subtraction either.
///
/// The rule used here - scale to microseconds, then round half-up in integers -
/// was chosen because it minimises the divergence: 2,240 mismatches per 200,000
/// four-decimal timestamps versus 7,680 for rounding the double directly.
///
/// Note that at a true tie neither answer is the more defensible one: `.6235` is
/// exactly equidistant between `.623` and `.624`, so rounding it up is as
/// justifiable as rounding it down.
enum ISO8601DateString {

    /// Days from 0000-03-01 (the start of a 400-year Gregorian cycle, and the
    /// base `civilDate` works in) to 2001-01-01, the reference epoch.
    ///
    /// Computed by inverting `civilDate` rather than looked up, which is worth
    /// noting: an earlier hand-written constant was wrong by 366 days and shifted
    /// every formatted date back a year.
    private static let referenceEpochDays = 730_791

    /// Formats `timeInterval`, measured in seconds since 2001-01-01 00:00:00 UTC.
    static func format(timeIntervalSinceReferenceDate timeInterval: Double) -> String {
        // Split into whole seconds and a non-negative fraction. `floor` (rather
        // than truncation) is what keeps negative intervals - dates before 2001 -
        // consistent with `DateFormatter`, which never emits a negative fraction.
        let totalSeconds = timeInterval.rounded(.down)
        let fraction = timeInterval - totalSeconds

        // `DateFormatter` rounds to whole milliseconds and zero-pads to the
        // format's width, so this is millisecond precision despite `SSSSSS`.
        //
        // ICU rounds the *decimal* rendering half-up rather than the binary
        // double, and the difference is not academic: Xcode writes section
        // timestamps with exactly 4 decimal places, so values like
        // 805375056.6135 - sitting exactly on a half millisecond - are common. A
        // plain `(fraction * 1_000).rounded()` rounds 613.4999999... down to 613
        // where ICU gives 614; that disagreed on 94 of 223,938 real section dates.
        //
        // Scaling to microseconds first recovers the intended decimal digit
        // (6135 -> 613.5) and then rounds half-up in integer arithmetic, with no
        // decimal string conversion.
        let microseconds = Int((fraction * 1_000_000).rounded())
        var milliseconds = (microseconds + 500) / 1_000
        var wholeSeconds = Int(totalSeconds)
        // Rounding up from .9995 or above carries into the next second.
        if milliseconds >= 1_000 {
            milliseconds -= 1_000
            wholeSeconds += 1
        }

        // Euclidean division, so a negative second count still yields a
        // non-negative time of day and borrows a day as it should.
        var dayCount = wholeSeconds / 86_400
        var secondOfDay = wholeSeconds % 86_400
        if secondOfDay < 0 {
            secondOfDay += 86_400
            dayCount -= 1
        }

        let (year, month, day) = civilDate(fromDaysSinceReferenceEpoch: dayCount)
        let hour = secondOfDay / 3_600
        let minute = (secondOfDay % 3_600) / 60
        let second = secondOfDay % 60

        // Written into a fixed-size stack buffer rather than an array, because for a format this
        // small the allocations dominate everything else. Do not rewrite this to build a `[UInt8]`
        // or to use a per-field scratch array: that costs about 8 allocations per date, twice per
        // section, and profiling showed almost all of the resulting time in malloc/free,
        // swift_release and the copy-on-write checks behind `Array.append` rather than in the
        // arithmetic.
        var buffer = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))
        return withUnsafeMutableBytes(of: &buffer) { raw -> String in
            let end = writeFields(into: raw.bindMemory(to: UInt8.self),
                                  year: year, month: month, day: day,
                                  hour: hour, minute: minute, second: second,
                                  milliseconds: milliseconds)
            // swiftlint:disable:next optional_data_string_conversion
            return String(decoding: UnsafeRawBufferPointer(rebasing: raw[0..<end]), as: UTF8.self)
        }
    }

    /// Writes the formatted date into `bytes` and returns how many bytes were used.
    ///
    /// The result is 27 bytes for a 4-digit year ("2026-07-10T11:17:36.613000Z"), so
    /// a 32-byte buffer leaves room to spare. Every field except the year is
    /// fixed-width, which is what lets each one be written without scratch storage.
    private static func writeFields(into bytes: UnsafeMutableBufferPointer<UInt8>,
                                    // swiftlint:disable:previous function_parameter_count
                                    year: Int,
                                    month: Int,
                                    day: Int,
                                    hour: Int,
                                    minute: Int,
                                    second: Int,
                                    milliseconds: Int) -> Int {
        var end = 0

        func write(_ byte: UInt8) {
            // Truncate rather than corrupt memory if the buffer ever gets too small.
            guard end < bytes.count else { return }
            bytes[end] = byte
            end += 1
        }

        /// Writes `value` most significant digit first, zero-padded to `width`.
        /// The divisor walks down from the widest place value, so no reversal or
        /// scratch buffer is needed.
        func writePadded(_ value: Int, width: Int) {
            var divisor = 1
            for _ in 1..<width {
                divisor *= 10
            }
            var remaining = value
            while divisor > 0 {
                write(UInt8(ascii: "0") + UInt8(remaining / divisor % 10))
                remaining %= divisor
                divisor /= 10
            }
        }

        writePadded(year, width: 4)
        write(UInt8(ascii: "-"))
        writePadded(month, width: 2)
        write(UInt8(ascii: "-"))
        writePadded(day, width: 2)
        write(UInt8(ascii: "T"))
        writePadded(hour, width: 2)
        write(UInt8(ascii: ":"))
        writePadded(minute, width: 2)
        write(UInt8(ascii: ":"))
        writePadded(second, width: 2)
        write(UInt8(ascii: "."))
        // 3 significant digits, zero-extended to the 6 the format asks for.
        writePadded(milliseconds, width: 3)
        write(UInt8(ascii: "0"))
        write(UInt8(ascii: "0"))
        write(UInt8(ascii: "0"))
        // `ZZZZZ` renders UTC as "Z" rather than "+00:00".
        write(UInt8(ascii: "Z"))
        return end
    }

    /// Converts a day offset from 2001-01-01 into a proleptic Gregorian date.
    ///
    /// This is Howard Hinnant's `civil_from_days`, which shifts the year to start
    /// in March so the leap day lands at the end of a 146,097-day (400-year)
    /// cycle and needs no special case.
    private static func civilDate(fromDaysSinceReferenceEpoch days: Int)
        -> (year: Int, month: Int, day: Int) { // swiftlint:disable:this large_tuple
        // Re-base onto 0000-03-01, the start of a 400-year cycle.
        let shifted = days + referenceEpochDays
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        // Month index with March as 0.
        let marchMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * marchMonth + 2) / 5 + 1
        let month = marchMonth < 10 ? marchMonth + 3 : marchMonth - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }
}
