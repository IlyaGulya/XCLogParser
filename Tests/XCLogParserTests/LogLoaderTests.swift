import Foundation
import Gzip
import XCTest
@testable import XCLogParser

class LogLoaderTests: XCTestCase {

    func testLoadFromURLPreservesEmbeddedNullBytes() throws {
        let directory = try TestUtils.createRandomTestDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.xcactivitylog")
        let value = "Sources/Bundle+Locali\u{0}zation"
        let contents = "SLF0#\(value.utf8.count)\"\(value)1#"
        let data = contents.data(using: .utf8)!
        try data.gzipped().write(to: url)

        let loadedContents = try LogLoader().loadFromURL(url)

        XCTAssertEqual(loadedContents, contents)
    }
}
