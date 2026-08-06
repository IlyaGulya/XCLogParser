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

/// Runs `body` inside an autorelease pool on Darwin, and calls it directly elsewhere.
///
/// The benchmark wraps each iteration in this so that the objects an iteration creates are gone before
/// the next one is measured. Without the pool on Darwin, autoreleased objects live until the enclosing
/// pool drains, which is after the whole run, and every footprint reading after the first would include
/// the previous iterations.
///
/// Linux has no Objective-C runtime and so no autorelease pools. Swift objects there are released by
/// ARC as soon as the last reference goes away, which is what the pool is being used to force. The
/// direct call is therefore the same behaviour, not a weaker version of it.
func withIterationPool<Result>(_ body: () throws -> Result) rethrows -> Result {
    #if canImport(Darwin)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}
