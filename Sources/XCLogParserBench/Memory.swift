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

/// A memory reading taken at one point in time.
struct MemorySample {

    /// Resident set size. These are the pages that are in physical memory now.
    ///
    /// `/usr/bin/time -l` reports this value as "maximum resident set size". The value is too noisy
    /// for this project. Three runs of one unchanged binary gave 1769, 1918 and 1750 MB. That spread
    /// is +/-10%. It hides any change smaller than about 200 MB.
    let resident: UInt64

    /// The memory the kernel charges to this process.
    ///
    /// This value counts what the process allocated. It does not count the clean file-backed pages
    /// that `resident` includes. A memory limit applies to this value.
    ///
    /// Each platform has its own source for it:
    ///
    /// | platform | source | field |
    /// |---|---|---|
    /// | Darwin | `task_info(TASK_VM_INFO)` | `phys_footprint` |
    /// | Linux | `/proc/self/status` | `RssAnon` |
    ///
    /// Both are much quieter than `resident`. On Darwin, five runs of unchanged code agreed to 0.1 MB
    /// per stage. That is about 70x quieter than `resident`. It resolves the 35 MB steps this project
    /// must see.
    let footprint: UInt64

    /// The highest `resident` value since the process started.
    ///
    /// The kernel does not let a process reset this value, so it is useful once per process only. The
    /// report prints it for reference and never uses it for per-stage accounting.
    let residentPeak: UInt64

    /// The reading that a failed measurement returns.
    ///
    /// `AllocationReporting` prints this as unavailable, never as zero bytes. "Not measured" and
    /// "allocated nothing" must not look alike.
    static let unavailable = MemorySample(resident: 0, footprint: 0, residentPeak: 0)

    /// The name of the counter that `footprint` comes from on this platform.
    ///
    /// The report prints this name, so that it points the reader at a counter the running platform
    /// actually has.
    static var footprintSourceName: String {
        #if canImport(Darwin)
        return "phys_footprint"
        #else
        return "RssAnon"
        #endif
    }
}

/// Reads the memory counters of this process.
///
/// A stage that runs second in a process can report a footprint far below its real cost, because the
/// allocator keeps some pages from the earlier stage and the later stage allocates from those. This is
/// why `--encode-path` and `--warmup 0` exist, and it holds on both platforms. What differs is how it
/// shows up:
///
/// - On Darwin, `phys_footprint` never goes down, so a second stage reads near zero every time.
/// - On Linux, `RssAnon` does go down, but only for the pages the allocator chose to release. Three
///   300 MB stages in one process read 300.1, 300.0 and 149.9 MB.
///
/// The Linux case is the more dangerous one: a near-zero reading is obviously wrong, and a reading
/// that is half right looks plausible.
func memorySample() -> MemorySample {
    return platformMemorySample()
}
