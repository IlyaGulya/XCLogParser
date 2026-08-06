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

enum BenchError: Error, CustomStringConvertible {
    // `notUTF8` was removed with the decode stage: nothing validates UTF-8 up front any more, since the
    // lexer reads bytes directly.
    case noLogs
    case unsupportedReport(String)
    case unknownEncodePath(String)
    case unreadableBaseline(String, String)

    var description: String {
        switch self {
        case .noLogs: return "No .xcactivitylog files found. Pass paths explicitly or populate Benchmarks/Logs."
        case .unsupportedReport(let type): return "Reporter produced \(type), which the bench cannot size."
        case .unknownEncodePath(let value):
            return "Unknown --encode-path \(value). Expected both, buffered or streaming."
        // Fails the run rather than skipping the comparison: an unreadable baseline that printed a
        // warning and carried on would report "no regressions" for a check that never happened.
        case .unreadableBaseline(let path, let reason):
            return "Cannot use \(path) as a baseline: \(reason). Expected a file written by --json."
        }
    }
}

// MARK: - CLI

struct Options {
    var paths: [String] = []
    var iterations = 3
    var warmup = 1
    var redacted = false
    var withoutBuildSpecificInformation = false
    var jsonOutput: String?
    var encodePath = EncodePath.both
    /// A previous run's `--json` file to diff this run against.
    var baseline: String?
}

func printUsage() {
    print("""
    xclogparser-bench — stage-by-stage parsing benchmark

    USAGE: xclogparser-bench [logs...] [options]

    When no logs are given, every .xcactivitylog under Benchmarks/Logs is used.

    OPTIONS:
      -n, --iterations <n>    Measured iterations per log (default 3)
          --warmup <n>        Unmeasured warmup iterations per log (default 1).
                              Use 0 to measure memory: a warmup leaves the heap
                              grown, and phys_footprint never gives those pages
                              back, so footprints become cumulative totals.
          --redacted          Redact the user directory while lexing
          --without-build-specific-information
                              Strip build-specific information while lexing
          --json <path>       Also write the results as JSON
          --baseline <path>   Diff this run against a previous --json file and
                              print regressions and improvements separately.
                              Timings are judged at ±5% and ±1 ms on p50/p90;
                              counters exactly, since they are deterministic
                              where the timings are not. Matched by log name, so
                              baseline and current must cover the same logs.
          --encode-path <p>   Which encode path to measure: both (default),
                              buffered or streaming. Only the encode stage that
                              runs first in a process has a falsifiable
                              footprint - phys_footprint never releases pages,
                              so a second encode allocates from pages the first
                              already mapped and reads near-zero whatever it
                              does. Pick one path per process to trust its
                              memory figure; both still times both.
      -h, --help              Show this message
    """)
}

// One branch per supported flag; splitting it up would only scatter the flag list.
// swiftlint:disable:next cyclomatic_complexity
func parseOptions() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while let arg = args.first {
        args.removeFirst()
        switch arg {
        case "--iterations", "-n":
            options.iterations = Int(args.first ?? "") ?? options.iterations
            if !args.isEmpty { args.removeFirst() }
        case "--warmup":
            options.warmup = Int(args.first ?? "") ?? options.warmup
            if !args.isEmpty { args.removeFirst() }
        case "--redacted":
            options.redacted = true
        case "--without-build-specific-information":
            options.withoutBuildSpecificInformation = true
        case "--json":
            options.jsonOutput = args.first
            if !args.isEmpty { args.removeFirst() }
        case "--baseline":
            options.baseline = args.first
            if !args.isEmpty { args.removeFirst() }
        case "--encode-path":
            let value = args.first ?? ""
            guard let path = EncodePath(rawValue: value) else {
                FileHandle.standardError
                    .write(Data("error: \(BenchError.unknownEncodePath(value).description)\n".utf8))
                exit(1)
            }
            options.encodePath = path
            args.removeFirst()
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            options.paths.append(arg)
        }
    }
    return options
}

func discoverLogs(_ options: Options) throws -> [URL] {
    if !options.paths.isEmpty {
        return options.paths.map { URL(fileURLWithPath: $0) }
    }
    let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Benchmarks/Logs")
    let contents = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                 includingPropertiesForKeys: nil)) ?? []
    let logs = contents.filter { $0.pathExtension == "xcactivitylog" }.sorted { $0.path < $1.path }
    guard !logs.isEmpty else { throw BenchError.noLogs }
    return logs
}
