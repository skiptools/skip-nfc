// Copyright 2023–2025 Skip
// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
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

/// An NFCAdapter that wraps `CoreNFC.NFCNDEFReaderSession` or `CoreNFC.NFCTagReaderSession` on iOS and `android.nfc.NfcAdapter` on Android.
///
/// https://developer.apple.com/documentation/corenfc/nfcndefreadersession
/// https://developer.apple.com/documentation/corenfc/nfctagreadersession
/// https://developer.android.com/reference/android/nfc/NfcAdapter
///
/// **Disclaimer**: This is all completely untested and based purely on guesswork and skimming the docs without any real understanding of NFC.
public final class NFCAdapter: NFCAdapterBase {
    private var messageHandler: ((NDEFMessage) -> ())?
    private var tagHandler: ((NFCTagImpl) -> ())?
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

    public var isAvailable: Bool {
        #if SKIP
        return self.nfcAdapter?.isReaderOptionSupported() == true
        #elseif canImport(CoreNFC)
        return NFCNDEFReaderSession.readingAvailable
        #else
        return false
        #endif
    }

    public var isReady: Bool {
        #if SKIP
        return self.nfcAdapter?.isReaderOptionEnabled() == true
        #elseif canImport(CoreNFC)
        return self.nfcSession?.isReady == true
        #else
        return false
        #endif
    }


    /// For iOS, set the alert message for the user when initiating the NFC scanning. E.g., “Hold your device near the NFC tag”
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

    public func startScanning(messageHandler: ((NDEFMessage) -> ())?, tagHandler: ((NFCTagImpl) -> ())? = nil) {
        self.messageHandler = messageHandler
        self.tagHandler = tagHandler
        #if SKIP
        var flags = 0
        // example of setting flags on the reader scan
        // https://developer.android.com/reference/android/nfc/NfcAdapter#FLAG_READER_NFC_A
        //flags = NfcAdapter.FLAG_READER_NFC_A
        // https://developer.android.com/reference/android/nfc/NfcAdapter#FLAG_READER_SKIP_NDEF_CHECK
        //flags = flags | NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK
        self.nfcAdapter?.enableReaderMode(activity, self, flags, nil)
        #elseif canImport(CoreNFC)
        self.nfcSession?.begin()
        #endif
    }

    public func stopScanning() {
        #if SKIP
        self.nfcAdapter?.disableReaderMode(activity)
        #elseif canImport(CoreNFC)
        self.nfcSession?.invalidate()
        #endif
        self.messageHandler = nil
        self.tagHandler = nil
    }

    func handleMessage(_ message: NDEFMessage) {
        self.messageHandler?(message)
        return
    }

    func handleTag(_ tag: NFCTagImpl) {
        self.tagHandler?(tag)
        return
    }

    func handleError(_ error: Error) {
        // TODO: proper error handling
        logger.error("NFC error: \(error)")
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
        // https://developer.android.com/reference/android/nfc/tech/Ndef
        if self.messageHandler != nil {
            if let ndef: Ndef = Ndef.get(tag) {
                ndef.connect()
                if let message: NdefMessage = ndef.getNdefMessage() {
                    handleMessage(NDEFMessage(platformValue: message))
                }
            }
        }
        if let tagHandler = self.tagHandler {
            if let tagImpl = NFCFTag.PlatformValue.get(tag) {
                tagHandler(NFCFTag(platformValue: tagImpl))
            }
            if let tagImpl = NFCVTag.PlatformValue.get(tag) {
                tagHandler(NFCVTag(platformValue: tagImpl))
            }
            if let tagImpl = NFCMTag.PlatformValue.get(tag) {
                tagHandler(NFCMTag(platformValue: tagImpl))
            }
        }
    }
}
#elseif canImport(CoreNFC)
extension NFCAdapter: NFCNDEFReaderSessionDelegate {
    public func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: any Error) {
        self.handleError(error)
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
        self.handleError(error)
    }
    
    public func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        for tag in tags {
            switch tag {
            case .feliCa(let tagImpl): // NFCFeliCaTag
                handleNFCTagMessage(tagImpl)
                let tagType = NFCFTag(platformValue: tagImpl)
                self.tagHandler?(tagType)
            case .iso7816(let tagImpl): // NFCISO7816Tag
                // which tag class should this be?
                handleNFCTagMessage(tagImpl)
            case .iso15693(let tagImpl): // NFCISO15693Tag
                handleNFCTagMessage(tagImpl)
                let tagType = NFCVTag(platformValue: tagImpl)
                self.tagHandler?(tagType)
            case .miFare(let tagImpl): // NFCMiFareTag
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
                self.handleError(error)
            }
        }
    }
}
#endif

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

    /// The payload, as defined by the NDEF specification.
    public var payload: Data {
        #if SKIP
        return Data(platformValue: platformValue.getPayload())
        #elseif canImport(CoreNFC)
        return platformValue.payload
        #else
        return Data()
        #endif
    }

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

public protocol NFCTagImpl {
    //func readMessage() async throws -> NDEFMessage
    //func writeMessage(_ message: NDEFMessage) async throws
}

/// Provides access to NFC-V (ISO 15693) properties and I/O operations on a Tag.
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

    public func readMessage() async throws -> NDEFMessage {
        #if SKIP
        fatalError("TODO")
        #elseif canImport(CoreNFC)
        try await NDEFMessage(platformValue: platformValue.readNDEF())
        #else
        fatalError("not implemented")
        #endif
    }

    public func writeMessage(_ message: NDEFMessage) async throws {
        #if SKIP
        fatalError("TODO")
        #elseif canImport(CoreNFC)
        try await platformValue.writeNDEF(message.platformValue)
        #else
        fatalError("not implemented")
        #endif
    }
}

/// Provides access to NFC-F (JIS 6319-4) properties and I/O operations on a Tag.
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

    public func readMessage() async throws -> NDEFMessage {
        #if SKIP
        fatalError("TODO")
        #elseif canImport(CoreNFC)
        try await NDEFMessage(platformValue: platformValue.readNDEF())
        #else
        fatalError("not implemented")
        #endif
    }

    public func writeMessage(_ message: NDEFMessage) async throws {
        #if SKIP
        fatalError("TODO")
        #elseif canImport(CoreNFC)
        try await platformValue.writeNDEF(message.platformValue)
        #else
        fatalError("not implemented")
        #endif
    }
}


/// Provides access to MIFARE Classic properties and I/O operations on a Tag.
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

    public func readMessage() async throws -> NDEFMessage {
        #if SKIP
        fatalError("TODO")
        #elseif canImport(CoreNFC)
        try await NDEFMessage(platformValue: platformValue.readNDEF())
        #else
        fatalError("not implemented")
        #endif
    }

    public func writeMessage(_ message: NDEFMessage) async throws {
        #if SKIP
        fatalError("TODO")
        #elseif canImport(CoreNFC)
        try await platformValue.writeNDEF(message.platformValue)
        #else
        fatalError("not implemented")
        #endif
    }
}
#endif
