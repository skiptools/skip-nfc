// SPDX-License-Identifier: MPL-2.0

import XCTest
import OSLog
import Foundation
@testable import SkipNFC

let logger: Logger = Logger(subsystem: "SkipNFC", category: "Tests")

@available(macOS 13, *)
final class SkipNFCTests: XCTestCase {

    func testSkipNFC() throws {
        logger.log("running testSkipNFC")
        XCTAssertEqual(1 + 2, 3, "basic test")
    }

    func testDecodeType() throws {
        // load the TestData.json file from the Resources folder and decode it into a struct
        let resourceURL: URL = try XCTUnwrap(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        XCTAssertEqual("SkipNFC", testData.testModuleName)
    }

}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
