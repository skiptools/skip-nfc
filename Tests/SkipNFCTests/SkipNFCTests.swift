// Copyright 2023–2026 Skip
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
        let resourceURL: URL = try XCTUnwrap(Bundle.module.url(forResource: "TestData", withExtension: "json"))
        let testData = try JSONDecoder().decode(TestData.self, from: Data(contentsOf: resourceURL))
        XCTAssertEqual("SkipNFC", testData.testModuleName)
    }

    func testNFCErrorCases() throws {
        // Verify all error cases can be constructed
        let errors: [NFCError] = [
            .notAvailable,
            .tagNotNDEF,
            .tagReadOnly,
            .readFailed("msg"),
            .writeFailed("msg"),
            .connectionFailed("msg"),
            .transceiveFailed("msg"),
            .sessionError("msg")
        ]
        XCTAssertEqual(errors.count, 8)
        // Verify they produce non-empty string descriptions
        for err in errors {
            XCTAssertFalse("\(err)".isEmpty)
        }
    }

    func testNDEFRecordTypeName() throws {
        // Verify TypeName enum values exist
        let types: [NDEFRecord.TypeName] = [.empty, .nfcWellKnown, .media, .absoluteURI, .nfcExternal, .unknown, .unchanged]
        XCTAssertEqual(types.count, 7)
    }

    func testPollingOptions() throws {
        let empty = NFCAdapter.PollingOption(rawValue: 0)
        XCTAssertTrue(empty.isEmpty)

        let iso14443 = NFCAdapter.PollingOption.iso14443
        XCTAssertTrue(iso14443.contains(.iso14443))
        XCTAssertFalse(iso14443.contains(.iso15693))

        var combined = NFCAdapter.PollingOption.iso14443
        combined.insert(.iso15693)
        combined.insert(.iso18092)
        XCTAssertTrue(combined.contains(.iso14443))
        XCTAssertTrue(combined.contains(.iso15693))
        XCTAssertTrue(combined.contains(.iso18092))
        XCTAssertFalse(combined.contains(.pace))
    }

    func testMakeTextRecord() throws {
        #if !os(macOS) || SKIP
        let record = NDEFRecord.makeTextRecord(text: "Hello NFC", locale: "en")
        XCTAssertEqual(record.typeName, .nfcWellKnown)
        let text = record.textContent
        XCTAssertEqual(text, "Hello NFC")
        #endif
    }

    func testMakeURIRecord() throws {
        #if !os(macOS) || SKIP
        let record = NDEFRecord.makeURIRecord(url: "https://skip.dev")
        XCTAssertEqual(record.typeName, .nfcWellKnown)
        let url = record.urlContent
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.absoluteString, "https://skip.dev")
        #endif
    }

    func testMakeMessageFromRecords() throws {
        #if !os(macOS) || SKIP
        let textRecord = NDEFRecord.makeTextRecord(text: "Test")
        let uriRecord = NDEFRecord.makeURIRecord(url: "https://skip.dev")
        let message = NDEFMessage.makeMessage(records: [textRecord, uriRecord])
        XCTAssertEqual(message.records.count, 2)
        #endif
    }
}

struct TestData : Codable, Hashable {
    var testModuleName: String
}
