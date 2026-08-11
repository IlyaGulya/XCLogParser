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

#if !canImport(Darwin)

import Foundation

/// Reads the memory counters from `/proc/self/status`.
///
/// `RssAnon` is the closest match for Darwin's `phys_footprint`. It counts anonymous pages only, so it
/// leaves out the file-backed pages of the Swift runtime. Those pages are about 17 MB and they move
/// `VmRSS` around for reasons that have nothing to do with the code under test.
///
/// This was checked against a program that allocates a known 500 MB and touches every page:
///
/// | field | before | after | error |
/// |---|---|---|---|
/// | `RssAnon` | 1.4 MB | 501.6 MB | 0.04% |
/// | `VmRSS` | 17.5 MB | 518.8 MB | carries 17 MB of file pages |
///
/// `Pss` from `/proc/self/smaps_rollup` tracks the allocation just as closely. It is not used here.
/// `Pss` divides each shared page by the number of processes that map it. For a benchmark that runs in
/// one process, that division only adds noise.
func platformMemorySample() -> MemorySample {
    // One read for all three fields. The three must describe the same instant. Separate reads can
    // catch the process mid-allocation and return a `resident` below `footprint`, which the report
    // would then show as a negative stage cost.
    guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else {
        return .unavailable
    }

    var resident: UInt64 = 0
    var anonymous: UInt64 = 0
    var peak: UInt64 = 0

    for line in status.split(separator: "\n") {
        guard let field = line.split(separator: ":").first else { continue }
        switch field {
        case "VmRSS": resident = bytes(in: line)
        case "RssAnon": anonymous = bytes(in: line)
        case "VmHWM": peak = bytes(in: line)
        default: continue
        }
    }

    // `RssAnon` arrived in Linux 4.5. An older kernel leaves it at zero. The fallback to `VmRSS`
    // reports a noisier figure. The alternative is a benchmark that measures nothing and does not say
    // so.
    return MemorySample(resident: resident,
                        footprint: anonymous == 0 ? resident : anonymous,
                        residentPeak: peak)
}

/// The kernel writes these fields in kB and prints the unit on every line, and no version of this file
/// reports them in pages, so the conversion is fixed rather than parsed.
private func bytes(in line: Substring) -> UInt64 {
    guard let value = line.split(separator: " ").compactMap({ UInt64($0) }).first else { return 0 }
    return value * 1024
}

#endif
