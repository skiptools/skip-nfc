// Copyright 2023–2026 Skip
// SPDX-License-Identifier: MPL-2.0

#if !SKIP_BRIDGE
import Foundation
import OSLog
#if SKIP
import skip.ui.UIApplication
import android.app.Activity
import android.nfc.__
import android.nfc.tech.__
#elseif canImport(CoreNFC)
import CoreNFC
#endif

#if SKIP
// Cannot use typealias NSObject = java.lang.Object because it breaks the bridge generation
public protocol NFCAdapterBase { }
#else
public typealias NFCAdapterBase = NSObject
#endif

let logger: Logger = Logger(subsystem: "skip.nfc", category: "SkipNFC") // adb logcat '*:S' 'skip.nfc.SkipNFC:V'

// MARK: - NFCError

/// Errors that can occur during NFC operations.
public enum NFCError: Error {
    /// NFC hardware is not available on this device.
    case notAvailable
    /// The tag does not support NDEF.
    case tagNotNDEF
    /// The tag is read-only and cannot be written to.
    case tagReadOnly
    /// Failed to read from the tag.
    case readFailed(String)
    /// Failed to write to the tag.
    case writeFailed(String)
    /// Failed to connect to the tag.
    case connectionFailed(String)
    /// Failed to send a command to the tag.
    case transceiveFailed(String)
    /// A session or system error occurred.
    case sessionError(String)
}

// MARK: - NFCAdapter

/// An NFCAdapter that wraps `CoreNFC.NFCNDEFReaderSession` or `CoreNFC.NFCTagReaderSession` on iOS and `android.nfc.NfcAdapter` on Android.
///
/// https://developer.apple.com/documentation/corenfc/nfcndefreadersession
/// https://developer.apple.com/documentation/corenfc/nfctagreadersession
/// https://developer.android.com/reference/android/nfc/NfcAdapter
public final class NFCAdapter: NFCAdapterBase {
    private var messageHandler: ((NDEFMessage) -> ())?
    private var tagHandler: ((NFCTagImpl) -> ())?
    private var errorHandler: ((NFCError) -> ())?
    #if SKIP
    private var nfcAdapter: NfcAdapter?
    #elseif canImport(CoreNFC)
    private var nfcSession: NFCReaderSession?
    #endif

    public struct PollingOption: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let iso14443 = PollingOption(rawValue: 1 << 0)
        public static let iso15693 = PollingOption(rawValue: 1 << 1)
        public static let iso18092 = PollingOption(rawValue: 1 << 2)
        public static let pace = PollingOption(rawValue: 1 << 3)

        #if canImport(CoreNFC)
        fileprivate var coreNFCPollingOption: NFCTagReaderSession.PollingOption {
            var opts = NFCTagReaderSession.PollingOption()
            if self.contains(.iso14443) { opts.insert(.iso14443) }
            if self.contains(.iso15693) { opts.insert(.iso15693) }
            if self.contains(.iso18092) { opts.insert(.iso18092) }
            if self.contains(.pace) { opts.insert(.pace) }
            return opts
        }
        #elseif SKIP
        fileprivate var adapterPollTechnology: Int {
            var pollTech = 0
            func ornum(_ i: Int, j: Int) -> Int {
                // SKIP INSERT: return i or j
            }
            // FLAG_READER_NFC_A, FLAG_READER_NFC_B, FLAG_READER_NFC_F, FLAG_READER_NFC_V, and FLAG_READER_NFC_BARCODE
            if self.contains(.iso14443) { // IsoDep, NfcA, NfcB: ISO/IEC 14443 Type A/B
                pollTech = ornum(pollTech, NfcAdapter.FLAG_READER_NFC_A)
                pollTech = ornum(pollTech, NfcAdapter.FLAG_READER_NFC_B)
            }
            if self.contains(.iso15693) { // NfcV: ISO/IEC 15693
                pollTech = ornum(pollTech, NfcAdapter.FLAG_READER_NFC_V)
            }
            if self.contains(.iso18092) { // NfcF: NFC-F / FeliCa
                pollTech = ornum(pollTech, NfcAdapter.FLAG_READER_NFC_F)
            }
            if self.contains(.pace) {
                // not supported on Android
            }
            return pollTech
        }
        #endif
    }

    public init(pollingOptions: PollingOption = []) {
        #if SKIP
        self.nfcAdapter = NfcAdapter.getDefaultAdapter(self.activity)
        if !pollingOptions.isEmpty {
            self.nfcAdapter?.setDiscoveryTechnology(self.activity!, pollingOptions.adapterPollTechnology, NfcAdapter.FLAG_LISTEN_KEEP)
        }
        #elseif canImport(CoreNFC)
        super.init()
        if pollingOptions.isEmpty {
            self.nfcSession = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: false)
        } else {
            self.nfcSession = NFCTagReaderSession(pollingOption: pollingOptions.coreNFCPollingOption, delegate: self, queue: nil)
        }
        #endif
    }

    /// Whether NFC hardware is available on this device.
    public var isAvailable: Bool {
        #if SKIP
        return self.nfcAdapter?.isReaderOptionSupported() == true
        #elseif canImport(CoreNFC)
        return NFCNDEFReaderSession.readingAvailable
        #else
        return false
        #endif
    }

    /// Whether NFC is enabled and ready for use.
    public var isReady: Bool {
        #if SKIP
        return self.nfcAdapter?.isReaderOptionEnabled() == true
        #elseif canImport(CoreNFC)
        return self.nfcSession?.isReady == true
        #else
        return false
        #endif
    }

    /// For iOS, set the alert message for the user when initiating the NFC scanning. E.g., "Hold your device near the NFC tag"
    public var alertMessage: String? {
        get {
            #if canImport(CoreNFC)
            return self.nfcSession?.alertMessage
            #else
            return nil
            #endif
        }

        set {
            #if canImport(CoreNFC)
            self.nfcSession?.alertMessage = newValue ?? ""
            #else
            // no-op
            #endif
        }
    }

    /// Begin scanning for NFC tags.
    ///
    /// - Parameters:
    ///   - messageHandler: Called when an NDEF message is read from a tag.
    ///   - tagHandler: Called when a tag is discovered, providing access to the tag for read/write operations.
    ///   - errorHandler: Called when an error occurs during scanning.
    public func startScanning(messageHandler: ((NDEFMessage) -> ())? = nil, tagHandler: ((NFCTagImpl) -> ())? = nil, errorHandler: ((NFCError) -> ())? = nil) {
        self.messageHandler = messageHandler
        self.tagHandler = tagHandler
        self.errorHandler = errorHandler
        #if SKIP
        var flags = 0
        self.nfcAdapter?.enableReaderMode(activity, self, flags, nil)
        #elseif canImport(CoreNFC)
        self.nfcSession?.begin()
        #endif
    }

    /// Stop scanning for NFC tags.
    public func stopScanning() {
        #if SKIP
        self.nfcAdapter?.disableReaderMode(activity)
        #elseif canImport(CoreNFC)
        self.nfcSession?.invalidate()
        #endif
        self.messageHandler = nil
        self.tagHandler = nil
        self.errorHandler = nil
    }

    func handleMessage(_ message: NDEFMessage) {
        self.messageHandler?(message)
        return
    }

    func handleTag(_ tag: NFCTagImpl) {
        self.tagHandler?(tag)
        return
    }

    func handleError(_ error: NFCError) {
        logger.error("NFC error: \(error)")
        self.errorHandler?(error)
    }

    #if SKIP
    fileprivate var activity: android.app.Activity? {
        UIApplication.shared.androidActivity
    }
    #endif
}

#if SKIP
extension NFCAdapter: NfcAdapter.ReaderCallback {
    // SKIP @nobridge
    override func onTagDiscovered(tag: Tag) {
        if self.messageHandler != nil {
            if let ndef: Ndef = Ndef.get(tag) {
                do {
                    ndef.connect()
                    if let message: NdefMessage = ndef.getNdefMessage() {
                        handleMessage(NDEFMessage(platformValue: message))
                    }
                    ndef.close()
                } catch {
                    handleError(NFCError.readFailed("\(error)"))
                }
            }
        }
        if let tagHandler = self.tagHandler {
            if let tagImpl = IsoDep.get(tag) {
                tagHandler(NFCISODepTag(platformValue: tagImpl))
            } else if let tagImpl = NFCFTag.PlatformValue.get(tag) {
                tagHandler(NFCFTag(platformValue: tagImpl))
            } else if let tagImpl = NFCVTag.PlatformValue.get(tag) {
                tagHandler(NFCVTag(platformValue: tagImpl))
            } else if let tagImpl = NFCMTag.PlatformValue.get(tag) {
                tagHandler(NFCMTag(platformValue: tagImpl))
            }
        }
    }
}
#elseif canImport(CoreNFC)
extension NFCAdapter: NFCNDEFReaderSessionDelegate {
    public func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: any Error) {
        self.handleError(NFCError.sessionError("\(error)"))
    }

    public func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        for message in messages {
            handleMessage(NDEFMessage(platformValue: message))
        }
    }
}

extension NFCAdapter: NFCTagReaderSessionDelegate {
    public func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
    }

    public func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: any Error) {
        self.handleError(NFCError.sessionError("\(error)"))
    }

    public func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        for tag in tags {
            switch tag {
            case .feliCa(let tagImpl):
                handleNFCTagMessage(tagImpl)
                let tagType = NFCFTag(platformValue: tagImpl)
                self.tagHandler?(tagType)
            case .iso7816(let tagImpl):
                handleNFCTagMessage(tagImpl)
                let tagType = NFCISODepTag(platformValue: tagImpl)
                self.tagHandler?(tagType)
            case .iso15693(let tagImpl):
                handleNFCTagMessage(tagImpl)
                let tagType = NFCVTag(platformValue: tagImpl)
                self.tagHandler?(tagType)
            case .miFare(let tagImpl):
                handleNFCTagMessage(tagImpl)
                let tagType = NFCMTag(platformValue: tagImpl)
                self.tagHandler?(tagType)
            @unknown default:
                break
            }
        }
    }

    func handleNFCTagMessage(_ tag: NFCNDEFTag) {
        if self.messageHandler == nil { return }
        tag.readNDEF { message, error in
            if let message {
                self.handleMessage(NDEFMessage(platformValue: message))
            } else if let error {
                self.handleError(NFCError.readFailed("\(error)"))
            }
        }
    }
}
#endif

// MARK: - NDEFMessage

/// A parsed NFC Data Exchange Format message containing one or more records.
///
/// https://developer.android.com/reference/android/nfc/NdefMessage
/// https://developer.apple.com/documentation/corenfc/nfcndefmessage
public final class NDEFMessage {
    #if SKIP
    typealias PlatformValue = NdefMessage
    #elseif canImport(CoreNFC)
    typealias PlatformValue = NFCNDEFMessage
    #else
    typealias PlatformValue = Void
    #endif

    let platformValue: PlatformValue

    init(platformValue: PlatformValue) {
        self.platformValue = platformValue
    }

    /// Create an NDEF message from an array of records.
    public static func makeMessage(records: [NDEFRecord]) -> NDEFMessage {
        #if SKIP
        // SKIP INSERT: val platformRecords = kotlin.Array<android.nfc.NdefRecord>(records.count) { i -> records[i].platformValue }
        return NDEFMessage(platformValue: NdefMessage(platformRecords))
        #elseif canImport(CoreNFC)
        let platformRecords = records.map { $0.platformValue }
        return NDEFMessage(platformValue: NFCNDEFMessage(records: platformRecords))
        #else
        fatalError("not implemented")
        #endif
    }

    /// The records contained in this NDEF message.
    public var records: [NDEFRecord] {
        var records: [NDEFRecord] = []
        #if SKIP
        for record in self.platformValue.getRecords() {
            records.append(NDEFRecord(platformValue: record))
        }
        #elseif canImport(CoreNFC)
        for record in self.platformValue.records {
            records.append(NDEFRecord(platformValue: record))
        }
        #endif
        return records
    }
}

// MARK: - NDEFRecord

/// A single record within an NDEF message, containing typed payload data.
///
/// https://developer.android.com/reference/android/nfc/NdefRecord
/// https://developer.apple.com/documentation/corenfc/nfcndefpayload
public final class NDEFRecord {
    #if SKIP
    typealias PlatformValue = NdefRecord
    #elseif canImport(CoreNFC)
    typealias PlatformValue = NFCNDEFPayload
    #else
    typealias PlatformValue = Void
    #endif

    let platformValue: PlatformValue

    init(platformValue: PlatformValue) {
        self.platformValue = platformValue
    }

    // MARK: Record creation

    /// Create an NDEF text record.
    ///
    /// - Parameters:
    ///   - text: The text content.
    ///   - locale: The language code (e.g. "en", "fr"). Defaults to "en".
    /// - Returns: A new text record.
    public static func makeTextRecord(text: String, locale: String = "en") -> NDEFRecord {
        #if SKIP
        return NDEFRecord(platformValue: NdefRecord.createTextRecord(locale, text))
        #elseif canImport(CoreNFC)
        let payload = NFCNDEFPayload.wellKnownTypeTextPayload(string: text, locale: Locale(identifier: locale))!
        return NDEFRecord(platformValue: payload)
        #else
        fatalError("not implemented")
        #endif
    }

    /// Create an NDEF URI record.
    ///
    /// - Parameter url: The URL string (e.g. "https://skip.dev").
    /// - Returns: A new URI record.
    public static func makeURIRecord(url: String) -> NDEFRecord {
        #if SKIP
        return NDEFRecord(platformValue: NdefRecord.createUri(url))
        #elseif canImport(CoreNFC)
        let payload = NFCNDEFPayload.wellKnownTypeURIPayload(url: URL(string: url)!)!
        return NDEFRecord(platformValue: payload)
        #else
        fatalError("not implemented")
        #endif
    }

    /// Create an NDEF MIME type record.
    ///
    /// - Parameters:
    ///   - type: The MIME type (e.g. "application/json").
    ///   - data: The payload data.
    /// - Returns: A new MIME type record.
    public static func makeMIMERecord(type: String, data: Data) -> NDEFRecord {
        #if SKIP
        // SKIP INSERT: val platformData = data.platformValue
        return NDEFRecord(platformValue: NdefRecord.createMime(type, platformData))
        #elseif canImport(CoreNFC)
        let payload = NFCNDEFPayload(format: .media, type: type.data(using: .utf8)!, identifier: Data(), payload: data)
        return NDEFRecord(platformValue: payload)
        #else
        fatalError("not implemented")
        #endif
    }

    // MARK: Record properties

    /// The identifier of the payload, as defined by the NDEF specification.
    public var identifier: Data {
        #if SKIP
        return Data(platformValue: platformValue.getId())
        #elseif canImport(CoreNFC)
        return platformValue.identifier
        #else
        return Data()
        #endif
    }

    /// The type of the payload, as defined by the NDEF specification.
    public var type: Data {
        #if SKIP
        return Data(platformValue: platformValue.getType())
        #elseif canImport(CoreNFC)
        return platformValue.type
        #else
        return Data()
        #endif
    }

    /// The payload data, as defined by the NDEF specification.
    public var payload: Data {
        #if SKIP
        return Data(platformValue: platformValue.getPayload())
        #elseif canImport(CoreNFC)
        return platformValue.payload
        #else
        return Data()
        #endif
    }

    /// The type name format of this record.
    public var typeName: TypeName {
        #if SKIP
        switch platformValue.getTnf() {
        case NdefRecord.TNF_ABSOLUTE_URI: return .absoluteURI
        case NdefRecord.TNF_EMPTY: return .empty
        case NdefRecord.TNF_EXTERNAL_TYPE: return .nfcExternal
        case NdefRecord.TNF_UNCHANGED: return .unchanged
        case NdefRecord.TNF_UNKNOWN: return .unknown
        case NdefRecord.TNF_WELL_KNOWN: return .nfcWellKnown
        case NdefRecord.TNF_MIME_MEDIA: return .media
        default: return .unknown
        }
        #elseif canImport(CoreNFC)
        switch platformValue.typeNameFormat {
        case .empty: return .empty
        case .nfcWellKnown: return .nfcWellKnown
        case .media: return .media
        case .absoluteURI: return .absoluteURI
        case .nfcExternal: return .nfcExternal
        case .unknown: return .unknown
        case .unchanged: return .unchanged
        @unknown default: return .unknown
        }
        #else
        return .unknown
        #endif
    }

    // MARK: Content parsing

    /// Attempt to parse the payload as a text string.
    /// Returns `nil` if this is not a well-known text record.
    public var textContent: String? {
        guard typeName == .nfcWellKnown else { return nil }
        let payloadData = self.payload
        #if SKIP
        // NFC text record layout: [status byte] [language code] [text]
        // Status byte bits 5-0 = language code length
        if payloadData.count < 1 { return nil }
        let langLength = Int(payloadData[0]) & 0x3F
        if payloadData.count <= langLength + 1 { return nil }
        let textBytes = payloadData.subdata(in: (langLength + 1)..<payloadData.count)
        return String(data: textBytes, encoding: .utf8)
        #elseif canImport(CoreNFC)
        let (text, _) = platformValue.wellKnownTypeTextPayload()
        return text
        #else
        return nil
        #endif
    }

    /// Attempt to parse the payload as a URL.
    /// Returns `nil` if this is not a well-known URI record.
    public var urlContent: URL? {
        #if canImport(CoreNFC)
        return platformValue.wellKnownTypeURIPayload()
        #else
        guard typeName == .nfcWellKnown else { return nil }
        let payloadData = self.payload
        if payloadData.count < 1 { return nil }
        let prefixByte = Int(payloadData[0])
        let uriPrefixes = [
            "", "http://www.", "https://www.", "http://", "https://",
            "tel:", "mailto:", "ftp://anonymous:anonymous@", "ftp://ftp.",
            "ftps://", "sftp://", "smb://", "nfs://", "ftp://", "dav://",
            "news:", "telnet://", "imap:", "rtsp://", "urn:", "pop:",
            "sip:", "sips:", "tftp:", "btspp://", "btl2cap://",
            "btgoep://", "tcpobex://", "irdaobex://", "file://",
            "urn:epc:id:", "urn:epc:tag:", "urn:epc:pat:", "urn:epc:raw:",
            "urn:epc:", "urn:nfc:"
        ]
        let prefix = prefixByte < uriPrefixes.count ? uriPrefixes[prefixByte] : ""
        let bodyData = payloadData.subdata(in: 1..<payloadData.count)
        guard let body = String(data: bodyData, encoding: .utf8) else { return nil }
        return URL(string: prefix + body)
        #endif
    }

    /// The type name format of an NDEF record.
    public enum TypeName {
        case empty
        case nfcWellKnown
        case media
        case absoluteURI
        case nfcExternal
        case unknown
        case unchanged
    }
}

// MARK: - Tag Protocol and Implementations

/// Protocol for NFC tag implementations.
///
/// All conforming tag types provide `identifier`, `readMessage()`, `writeMessage()`, and `transceive()` methods.
/// These methods are defined on each concrete tag class rather than in the protocol
/// to avoid bridging callback conflicts in transpiled Kotlin.
public protocol NFCTagImpl {
    /// The unique identifier (UID) of the tag.
    var identifier: Data { get }
}

// MARK: - NFCISODepTag

/// Provides access to ISO-DEP (ISO 14443-4) properties and I/O operations on a tag.
/// This is the most common tag type for smart cards and payment cards.
///
/// https://developer.apple.com/documentation/corenfc/nfciso7816tag
/// https://developer.android.com/reference/android/nfc/tech/IsoDep
public final class NFCISODepTag: NFCTagImpl {
    #if SKIP
    typealias PlatformValue = IsoDep
    #elseif canImport(CoreNFC)
    typealias PlatformValue = NFCISO7816Tag
    #else
    typealias PlatformValue = Void
    #endif

    let platformValue: PlatformValue

    init(platformValue: PlatformValue) {
        self.platformValue = platformValue
    }

    /// The unique identifier (UID) of the tag.
    public var identifier: Data {
        #if SKIP
        return Data(platformValue: platformValue.getTag().getId())
        #elseif canImport(CoreNFC)
        return platformValue.identifier
        #else
        return Data()
        #endif
    }

    /// The historical bytes from the tag's answer-to-select response, if available.
    public var historicalBytes: Data? {
        #if SKIP
        if let bytes = platformValue.getHistoricalBytes() {
            return Data(platformValue: bytes)
        }
        return nil
        #elseif canImport(CoreNFC)
        return platformValue.historicalBytes
        #else
        return nil
        #endif
    }

    /// Read the NDEF message stored on the tag.
    public func readMessage() async throws -> NDEFMessage {
        #if SKIP
        let tag = platformValue.getTag()
        guard let ndef = Ndef.get(tag) else {
            throw NFCError.tagNotNDEF
        }
        ndef.connect()
        guard let message = ndef.getNdefMessage() else {
            ndef.close()
            throw NFCError.readFailed("No NDEF message on tag")
        }
        ndef.close()
        return NDEFMessage(platformValue: message)
        #elseif canImport(CoreNFC)
        return try await NDEFMessage(platformValue: platformValue.readNDEF())
        #else
        fatalError("not implemented")
        #endif
    }

    /// Write an NDEF message to the tag.
    public func writeMessage(_ message: NDEFMessage) async throws {
        #if SKIP
        let tag = platformValue.getTag()
        guard let ndef = Ndef.get(tag) else {
            throw NFCError.tagNotNDEF
        }
        ndef.connect()
        if !ndef.isWritable() {
            ndef.close()
            throw NFCError.tagReadOnly
        }
        ndef.writeNdefMessage(message.platformValue)
        ndef.close()
        #elseif canImport(CoreNFC)
        try await platformValue.writeNDEF(message.platformValue)
        #else
        fatalError("not implemented")
        #endif
    }

    /// Send a raw APDU command to the tag and return the response data.
    ///
    /// - Parameter data: The command data to send.
    /// - Returns: The response data from the tag.
    public func transceive(data: Data) async throws -> Data {
        #if SKIP
        platformValue.connect()
        // SKIP INSERT: val response = platformValue.transceive(data.platformValue)
        let result = Data(platformValue: response)
        platformValue.close()
        return result
        #elseif canImport(CoreNFC)
        let apdu = NFCISO7816APDU(data: data)!
        let (responseData, _, _) = try await platformValue.sendCommand(apdu: apdu)
        return responseData
        #else
        fatalError("not implemented")
        #endif
    }
}

// MARK: - NFCVTag

/// Provides access to NFC-V (ISO 15693) properties and I/O operations on a tag.
///
/// https://developer.apple.com/documentation/corenfc/nfciso15693tag
/// https://developer.android.com/reference/android/nfc/tech/NfcV
public final class NFCVTag: NFCTagImpl {
    #if SKIP
    typealias PlatformValue = NfcV
    #elseif canImport(CoreNFC)
    typealias PlatformValue = NFCISO15693Tag
    #else
    typealias PlatformValue = Void
    #endif

    let platformValue: PlatformValue

    init(platformValue: PlatformValue) {
        self.platformValue = platformValue
    }

    /// The unique identifier (UID) of the tag.
    public var identifier: Data {
        #if SKIP
        return Data(platformValue: platformValue.getTag().getId())
        #elseif canImport(CoreNFC)
        return platformValue.identifier
        #else
        return Data()
        #endif
    }

    /// Read the NDEF message stored on the tag.
    public func readMessage() async throws -> NDEFMessage {
        #if SKIP
        let tag = platformValue.getTag()
        guard let ndef = Ndef.get(tag) else {
            throw NFCError.tagNotNDEF
        }
        ndef.connect()
        guard let message = ndef.getNdefMessage() else {
            ndef.close()
            throw NFCError.readFailed("No NDEF message on tag")
        }
        ndef.close()
        return NDEFMessage(platformValue: message)
        #elseif canImport(CoreNFC)
        return try await NDEFMessage(platformValue: platformValue.readNDEF())
        #else
        fatalError("not implemented")
        #endif
    }

    /// Write an NDEF message to the tag.
    public func writeMessage(_ message: NDEFMessage) async throws {
        #if SKIP
        let tag = platformValue.getTag()
        guard let ndef = Ndef.get(tag) else {
            throw NFCError.tagNotNDEF
        }
        ndef.connect()
        if !ndef.isWritable() {
            ndef.close()
            throw NFCError.tagReadOnly
        }
        ndef.writeNdefMessage(message.platformValue)
        ndef.close()
        #elseif canImport(CoreNFC)
        try await platformValue.writeNDEF(message.platformValue)
        #else
        fatalError("not implemented")
        #endif
    }

    /// Send a raw command to the tag and return the response data.
    ///
    /// - Parameter data: The command data to send.
    /// - Returns: The response data from the tag.
    public func transceive(data: Data) async throws -> Data {
        #if SKIP
        platformValue.connect()
        // SKIP INSERT: val response = platformValue.transceive(data.platformValue)
        let result = Data(platformValue: response)
        platformValue.close()
        return result
        #elseif canImport(CoreNFC)
        let response = try await platformValue.customCommand(requestFlags: [], customCommandCode: 0, customRequestParameters: data)
        return response
        #else
        fatalError("not implemented")
        #endif
    }
}

// MARK: - NFCFTag

/// Provides access to NFC-F (JIS 6319-4 / FeliCa) properties and I/O operations on a tag.
///
/// https://developer.apple.com/documentation/corenfc/nfcfelicatag
/// https://developer.android.com/reference/android/nfc/tech/NfcF
public final class NFCFTag: NFCTagImpl {
    #if SKIP
    typealias PlatformValue = NfcF
    #elseif canImport(CoreNFC)
    typealias PlatformValue = NFCFeliCaTag
    #else
    typealias PlatformValue = Void
    #endif

    let platformValue: PlatformValue

    init(platformValue: PlatformValue) {
        self.platformValue = platformValue
    }

    /// The unique identifier (UID) of the tag.
    public var identifier: Data {
        #if SKIP
        return Data(platformValue: platformValue.getTag().getId())
        #elseif canImport(CoreNFC)
        return platformValue.currentIDm
        #else
        return Data()
        #endif
    }

    /// Read the NDEF message stored on the tag.
    public func readMessage() async throws -> NDEFMessage {
        #if SKIP
        let tag = platformValue.getTag()
        guard let ndef = Ndef.get(tag) else {
            throw NFCError.tagNotNDEF
        }
        ndef.connect()
        guard let message = ndef.getNdefMessage() else {
            ndef.close()
            throw NFCError.readFailed("No NDEF message on tag")
        }
        ndef.close()
        return NDEFMessage(platformValue: message)
        #elseif canImport(CoreNFC)
        return try await NDEFMessage(platformValue: platformValue.readNDEF())
        #else
        fatalError("not implemented")
        #endif
    }

    /// Write an NDEF message to the tag.
    public func writeMessage(_ message: NDEFMessage) async throws {
        #if SKIP
        let tag = platformValue.getTag()
        guard let ndef = Ndef.get(tag) else {
            throw NFCError.tagNotNDEF
        }
        ndef.connect()
        if !ndef.isWritable() {
            ndef.close()
            throw NFCError.tagReadOnly
        }
        ndef.writeNdefMessage(message.platformValue)
        ndef.close()
        #elseif canImport(CoreNFC)
        try await platformValue.writeNDEF(message.platformValue)
        #else
        fatalError("not implemented")
        #endif
    }

    /// Send a raw command to the tag and return the response data.
    ///
    /// - Parameter data: The command data to send.
    /// - Returns: The response data from the tag.
    public func transceive(data: Data) async throws -> Data {
        #if SKIP
        platformValue.connect()
        // SKIP INSERT: val response = platformValue.transceive(data.platformValue)
        let result = Data(platformValue: response)
        platformValue.close()
        return result
        #elseif canImport(CoreNFC)
        return try await platformValue.sendFeliCaCommand(commandPacket: data)
        #else
        fatalError("not implemented")
        #endif
    }
}

// MARK: - NFCMTag

/// Provides access to MIFARE Classic properties and I/O operations on a tag.
///
/// https://developer.apple.com/documentation/corenfc/nfcmifaretag
/// https://developer.android.com/reference/android/nfc/tech/MifareClassic
public final class NFCMTag: NFCTagImpl {
    #if SKIP
    typealias PlatformValue = MifareClassic
    #elseif canImport(CoreNFC)
    typealias PlatformValue = NFCMiFareTag
    #else
    typealias PlatformValue = Void
    #endif

    let platformValue: PlatformValue

    init(platformValue: PlatformValue) {
        self.platformValue = platformValue
    }

    /// The unique identifier (UID) of the tag.
    public var identifier: Data {
        #if SKIP
        return Data(platformValue: platformValue.getTag().getId())
        #elseif canImport(CoreNFC)
        return platformValue.identifier
        #else
        return Data()
        #endif
    }

    /// Read the NDEF message stored on the tag.
    public func readMessage() async throws -> NDEFMessage {
        #if SKIP
        let tag = platformValue.getTag()
        guard let ndef = Ndef.get(tag) else {
            throw NFCError.tagNotNDEF
        }
        ndef.connect()
        guard let message = ndef.getNdefMessage() else {
            ndef.close()
            throw NFCError.readFailed("No NDEF message on tag")
        }
        ndef.close()
        return NDEFMessage(platformValue: message)
        #elseif canImport(CoreNFC)
        return try await NDEFMessage(platformValue: platformValue.readNDEF())
        #else
        fatalError("not implemented")
        #endif
    }

    /// Write an NDEF message to the tag.
    public func writeMessage(_ message: NDEFMessage) async throws {
        #if SKIP
        let tag = platformValue.getTag()
        guard let ndef = Ndef.get(tag) else {
            throw NFCError.tagNotNDEF
        }
        ndef.connect()
        if !ndef.isWritable() {
            ndef.close()
            throw NFCError.tagReadOnly
        }
        ndef.writeNdefMessage(message.platformValue)
        ndef.close()
        #elseif canImport(CoreNFC)
        try await platformValue.writeNDEF(message.platformValue)
        #else
        fatalError("not implemented")
        #endif
    }

    /// Send a raw MIFARE command to the tag and return the response data.
    ///
    /// - Parameter data: The command data to send.
    /// - Returns: The response data from the tag.
    public func transceive(data: Data) async throws -> Data {
        #if SKIP
        platformValue.connect()
        // SKIP INSERT: val response = platformValue.transceive(data.platformValue)
        let result = Data(platformValue: response)
        platformValue.close()
        return result
        #elseif canImport(CoreNFC)
        return try await platformValue.sendMiFareCommand(commandPacket: data)
        #else
        fatalError("not implemented")
        #endif
    }
}
#endif
