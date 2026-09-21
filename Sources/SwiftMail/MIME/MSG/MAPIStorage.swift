// MAPIStorage.swift
// Typed access to the MAPI properties of one storage inside a `.msg`.
//
// A `.msg` is a MAPI message serialized into a compound file (MS-OXMSG): each
// variable-length property is a stream named `__substg1.0_<id><type>`, the
// fixed-size ones are packed into `__properties_version1.0`, and recipients
// and attachments are sub-storages that carry the same layout recursively.

import Foundation
import SwiftCross

/// The MAPI property identifiers this parser reads.
enum MAPIPropertyID: UInt16 {
    case transportMessageHeaders = 0x007D
    case clientSubmitTime = 0x0039
    case messageDeliveryTime = 0x0E06
    case subject = 0x0037
    case normalizedSubject = 0x0E1D
    case senderName = 0x0C1A
    case senderEmailAddress = 0x0C1F
    case senderSMTPAddress = 0x5D01
    case sentRepresentingName = 0x0042
    case sentRepresentingEmailAddress = 0x0065
    case sentRepresentingSMTPAddress = 0x5D02
    case displayTo = 0x0E04
    case displayCc = 0x0E03
    case displayBcc = 0x0E02
    case internetMessageID = 0x1035
    case body = 0x1000
    case rtfCompressed = 0x1009
    case bodyHTML = 0x1013
    case internetCodepage = 0x3FDE
    case messageCodepage = 0x3FFD

    // Attachment properties
    case attachData = 0x3701
    case attachFilename = 0x3704
    case attachLongFilename = 0x3707
    case attachMIMETag = 0x370E
    case attachContentID = 0x3712
    case attachMethod = 0x3705
    case attachContentDisposition = 0x3716
    case attachFlags = 0x3714

    // Recipient properties
    case displayName = 0x3001
    case emailAddress = 0x3003
    case smtpAddress = 0x39FE
    case recipientType = 0x0C15
}

/// MAPI property types (MS-OXCDATA §2.11.1).
enum MAPIPropertyType: UInt16 {
    case int16 = 0x0002
    case int32 = 0x0003
    case boolean = 0x000B
    case string8 = 0x001E
    case unicode = 0x001F
    case systemTime = 0x0040
    case binary = 0x0102
}

/// How an attachment's content is stored (`PR_ATTACH_METHOD`).
enum MAPIAttachMethod: Int32 {
    case none = 0
    case byValue = 1
    case byReference = 2
    case byReferenceResolve = 3
    case byReferenceOnly = 4
    case embeddedMessage = 5
    case ole = 6
}

/// One storage of a `.msg` — the message itself, an attachment, or a recipient.
struct MAPIStorage {

    private let file: CompoundFile
    private let entry: CompoundFile.Entry

    /// Variable-length properties, keyed by the full tag (`id << 16 | type`).
    private let streams: [UInt32: CompoundFile.Entry]
    /// Sub-storages by name, including `__attach_…`, `__recip_…`, and the
    /// embedded-message storage `__substg1.0_3701000D`.
    private let storages: [String: CompoundFile.Entry]
    /// Fixed-size properties from `__properties_version1.0`, keyed by tag.
    private let fixed: [UInt32: [UInt8]]

    init(file: CompoundFile, entry: CompoundFile.Entry, isTopLevel: Bool) {
        self.file = file
        self.entry = entry

        var streams: [UInt32: CompoundFile.Entry] = [:]
        var storages: [String: CompoundFile.Entry] = [:]
        var propertiesStream: CompoundFile.Entry?

        for child in file.children(of: entry) {
            if child.name == "__properties_version1.0" {
                propertiesStream = child
            } else if child.name.hasPrefix("__substg1.0_"), let tag = Self.tag(fromStreamName: child.name) {
                // The embedded-message payload uses a substg *name* but is a
                // storage, so it is indexed with the sub-storages instead.
                if child.kind == .storage {
                    storages[child.name] = child
                } else {
                    streams[tag] = child
                }
            } else if child.kind == .storage {
                storages[child.name] = child
            }
        }

        self.streams = streams
        self.storages = storages
        self.fixed = propertiesStream.map {
            Self.fixedProperties(file.data(for: $0), isTopLevel: isTopLevel)
        } ?? [:]
    }

    // MARK: - Typed accessors

    /// A string property, preferring the Unicode stream over the code-page one.
    func string(_ id: MAPIPropertyID) -> String? {
        if let entry = streams[Self.tag(id, .unicode)] {
            let text = String(decodingUTF16LE: [UInt8](file.data(for: entry)))
            return text.isEmpty ? nil : text
        }
        if let entry = streams[Self.tag(id, .string8)] {
            let data = file.data(for: entry)
            guard !data.isEmpty else { return nil }
            return String(data: data, encoding: codePageEncoding)
                ?? String(data: data, encoding: .windowsCP1252)
        }
        return nil
    }

    /// A binary property.
    func data(_ id: MAPIPropertyID) -> Data? {
        guard let entry = streams[Self.tag(id, .binary)] else { return nil }
        let data = file.data(for: entry)
        return data.isEmpty ? nil : data
    }

    /// A 32-bit integer property from the packed fixed-size stream.
    func int32(_ id: MAPIPropertyID) -> Int32? {
        guard let value = fixed[Self.tag(id, .int32)], value.count >= 4 else { return nil }
        let raw = UInt32(value[0]) | (UInt32(value[1]) << 8) | (UInt32(value[2]) << 16) | (UInt32(value[3]) << 24)
        return Int32(bitPattern: raw)
    }

    /// A timestamp property, stored as a Windows FILETIME.
    func date(_ id: MAPIPropertyID) -> Date? {
        guard let value = fixed[Self.tag(id, .systemTime)], value.count >= 8 else { return nil }
        var ticks: UInt64 = 0
        for index in (0..<8).reversed() {
            ticks = (ticks << 8) | UInt64(value[index])
        }
        guard ticks > 0 else { return nil }
        // FILETIME counts 100-nanosecond intervals from 1601-01-01 UTC; the
        // constant is the gap from there to the Unix epoch.
        let seconds = Double(ticks) / 10_000_000 - 11_644_473_600
        guard seconds > -62_135_596_800, seconds < 253_402_300_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Sub-storages whose names start with `prefix`, in name order so that
    /// `#00000000`, `#00000001`, … keep the order Outlook wrote them in.
    func subStorages(prefix: String) -> [MAPIStorage] {
        storages.keys
            .filter { $0.hasPrefix(prefix) }
            .sorted()
            .compactMap { storages[$0] }
            .map { MAPIStorage(file: file, entry: $0, isTopLevel: false) }
    }

    /// The embedded-message storage of an attachment, if it has one.
    var embeddedMessage: MAPIStorage? {
        guard let storage = storages["__substg1.0_3701000D"] else { return nil }
        return MAPIStorage(file: file, entry: storage, isTopLevel: false)
    }

    // MARK: - Helpers

    /// The encoding for `PT_STRING8` values in this storage.
    private var codePageEncoding: String.Encoding {
        // A message written by a Unicode-capable client tags its code page;
        // without one, CP1252 is what Outlook assumes.
        for id in [MAPIPropertyID.internetCodepage, .messageCodepage] {
            if let codePage = int32(id), codePage > 0 {
                return RTFDeencapsulation.encoding(forCodePage: Int(codePage))
            }
        }
        return .windowsCP1252
    }

    private static func tag(_ id: MAPIPropertyID, _ type: MAPIPropertyType) -> UInt32 {
        (UInt32(id.rawValue) << 16) | UInt32(type.rawValue)
    }

    /// Parse the eight hex digits of a `__substg1.0_XXXXYYYY` stream name into
    /// a property tag. Names carrying a multi-value index suffix are rejected:
    /// this parser reads no multi-value properties, and accepting the prefix
    /// would silently alias every element onto the same tag.
    private static func tag(fromStreamName name: String) -> UInt32? {
        let digits = name.dropFirst("__substg1.0_".count)
        guard digits.count == 8, let value = UInt32(digits, radix: 16) else { return nil }
        return value
    }

    /// Unpack `__properties_version1.0` into tag → 8-byte value.
    ///
    /// The entries are uniform 16-byte records; only the header before them
    /// differs by storage kind (MS-OXMSG §2.4.1).
    private static func fixedProperties(_ data: Data, isTopLevel: Bool) -> [UInt32: [UInt8]] {
        let bytes = [UInt8](data)
        // Top-level messages carry recipient/attachment counters ahead of the
        // entries; attachment and recipient storages carry only the reserved
        // eight bytes. Embedded messages use the 24-byte form, which this
        // parser reaches through the top-level path.
        let header = isTopLevel ? 32 : 8
        guard bytes.count > header else { return [:] }

        var result: [UInt32: [UInt8]] = [:]
        var offset = header
        while offset + 16 <= bytes.count {
            let type = UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            let id = UInt32(bytes[offset + 2]) | (UInt32(bytes[offset + 3]) << 8)
            result[(id << 16) | type] = Array(bytes[(offset + 8)..<(offset + 16)])
            offset += 16
        }
        return result
    }
}
