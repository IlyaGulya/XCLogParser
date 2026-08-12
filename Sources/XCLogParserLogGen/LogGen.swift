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

/// Generates a gzipped `.xcactivitylog` from a profile.
public struct LogGen {

    struct Options {
        var profilePath: String?
        var outputPath: String?
        var seedOverride: UInt64?
        var wantsHelp = false
    }

    static func parseOptions(_ arguments: [String]) throws -> Options {
        var options = Options()
        var args = arguments
        while let arg = args.first {
            args.removeFirst()
            switch arg {
            case "--profile", "-p":
                options.profilePath = args.first
                if !args.isEmpty { args.removeFirst() }
            case "--output", "-o":
                options.outputPath = args.first
                if !args.isEmpty { args.removeFirst() }
            case "--seed":
                options.seedOverride = UInt64(args.first ?? "")
                if !args.isEmpty { args.removeFirst() }
            case "--help", "-h":
                options.wantsHelp = true
                return options
            default:
                throw LogGenError.usage("Unexpected argument \(arg). Use --help.")
            }
        }
        return options
    }

    public static func run(arguments: [String]) throws {
        let options = try parseOptions(arguments)
        if options.wantsHelp {
            printUsage()
            return
        }

        guard let profilePath = options.profilePath else {
            throw LogGenError.usage("Missing --profile. Use --help.")
        }
        guard let outputPath = options.outputPath else {
            throw LogGenError.usage("Missing --output. Use --help.")
        }

        var profile: Profile
        do {
            profile = try Profile.load(contentsOf: URL(fileURLWithPath: profilePath))
        } catch let error as LogGenError {
            throw error
        } catch {
            throw LogGenError.unreadableProfile(profilePath, "\(error)")
        }
        if let seedOverride = options.seedOverride {
            profile.seed = seedOverride
        }

        var builder = LogBuilder(profile: profile)
        let (document, stats) = builder.build()
        // Xcode stores these gzipped, and `LogLoader` gunzips before lexing, so an uncompressed file
        // would not be loadable and the gunzip stage would have nothing to measure.
        let compressed = try document.gzipped()
        try compressed.write(to: URL(fileURLWithPath: outputPath))

        report(profile: profile, stats: stats, raw: document.count, compressed: compressed.count,
               path: outputPath)
    }

    /// Prints requested against realised values.
    ///
    /// Both columns are shown because the realised numbers are sampled from a seeded distribution
    /// and will not land exactly on the request. A generator that printed only the profile would be
    /// asserting a shape it had not checked.
    private static func report(profile: Profile, stats: LogBuilder.Statistics,
                               raw: Int, compressed: Int, path: String) {
        print("Wrote \(path)")
        print("")
        print("                         requested      realised")
        print("  sections               \(pad(profile.sectionCount))\(pad(stats.sectionCount))")
        print("  diagnostic density     \(pad(percent(profile.diagnosticDensity)))"
            + "\(pad(percent(stats.diagnosticDensity)))")
        if let colon = profile.colonByteFrequency {
            print("  \":\" byte frequency     \(pad(percent(colon)))"
                + "\(pad(percent(stats.colonByteFrequency)))")
        }
        print("  clang sections         \(pad(percent(profile.clangSectionShare)))"
            + "\(pad(percent(stats.clangSectionShare)))")
        print("  errors                 \(pad(percent(profile.errorShare)))"
            + "\(pad(percent(stats.errorShare)))")
        print("  targets                \(pad(profile.targetCount))\(pad("-"))")
        print("  nesting depth          \(pad(profile.nestingDepth))\(pad("-"))")
        print("  grouping sections      \(pad("-"))\(pad(stats.intermediateSections))")
        print("  notices                \(pad("-"))\(pad(stats.noticeCount))")
        print("  distinct details       \(pad("-"))\(pad(stats.distinctDetails))")
        if let layout = profile.swiftDriverLayout {
            print("  SwiftDriver sections   \(pad("-"))\(pad(stats.swiftDriverSections))")
            print("  SwiftEmitModule        \(pad("-"))\(pad(stats.swiftEmitModuleSections))")
            print("  flagged targets        \(pad(percent(layout.flaggedTargetShare)))"
                + "\(pad(stats.flaggedTargets))")
            // The counts a fixture asserts against. Decoy lines are excluded, so these are what a
            // correct parse should find and nothing else.
            print("  function timing lines  \(pad("-"))\(pad(stats.functionTimingLines))")
            print("  type-check lines       \(pad("-"))\(pad(stats.typeCheckTimingLines))")
        }
        print("  section text           \(pad("-"))\(pad(bytes(stats.sectionTextBytes)))")
        print("  uncompressed           \(pad("-"))\(pad(bytes(raw)))")
        print("  compressed             \(pad("-"))\(pad(bytes(compressed)))")
        print("  seed                   \(pad("-"))\(pad(profile.seed))")
    }

    private static func pad(_ value: Any) -> String {
        return "\(value)".padding(toLength: max(14, "\(value)".count + 1), withPad: " ",
                                  startingAt: 0)
    }

    private static func percent(_ value: Double) -> String {
        return String(format: "%.2f%%", value * 100)
    }

    private static func bytes(_ count: Int) -> String {
        if count >= 1_048_576 {
            return String(format: "%.1f MB", Double(count) / 1_048_576)
        }
        if count >= 1024 {
            return String(format: "%.1f KB", Double(count) / 1024)
        }
        return "\(count) B"
    }

    private static func printUsage() {
        print("""
        xclogparser-loggen — generate an .xcactivitylog for benchmarking

        USAGE: xclogparser-loggen --profile <path> --output <path> [--seed <n>]

        Generated logs are reproducible: the same profile and seed always produce
        byte-identical output, so a benchmark run months apart compares the same
        input. Profiles live in Benchmarks/Profiles and are checked in; the logs
        they produce are not, since they are derived artifacts.

        OPTIONS:
          -p, --profile <path>  YAML profile describing the log to generate
          -o, --output <path>   Where to write the gzipped .xcactivitylog
              --seed <n>        Override the profile's seed
          -h, --help            Show this message
        """)
    }
}
