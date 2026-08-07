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

/// `NoticeType.fromTitle(logSection.text)`, computed on first use and reused for the whole section.
///
/// A message with an empty `categoryIdent` is classified from the entire section text instead of its
/// own title, and that text is the same string for every message in the section - so the resulting
/// `NoticeType` is the same too. `fromTitle` is not free on such an input: one of its cases is a
/// `Contains("Command PhaseScriptExecution")` over the full text.
///
/// A class, so the memoised value is shared by every message in the section rather than copied per
/// message. It stays lazy because the empty-`categoryIdent` case is rare - 1 of 21,701 messages on
/// baseline-noflags, 2 of 12,888 on flagged-10x-fleet - so classifying every section eagerly would
/// add work to the common path in order to save it on a rare one.
final class SectionTextNoticeType {
    private let text: String
    private var computed = false
    private var value: NoticeType?

    init(text: String) {
        self.text = text
    }

    var noticeType: NoticeType? {
        if !computed {
            value = NoticeType.fromTitle(text)
            computed = true
        }
        return value
    }
}
