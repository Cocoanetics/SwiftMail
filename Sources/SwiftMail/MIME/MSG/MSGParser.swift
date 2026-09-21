// MSGParser.swift
// Parse an Outlook `.msg` (MS-OXMSG) container into a Message.
//
// The result is the same ``Message`` an `.eml` parses to, so parts,
// attachments, addresses and dates keep working downstream regardless of which
// platform the mail was saved on.
//
// The body needs more care than the envelope. Outlook usually stores no HTML
// stream at all: the rich body is `PR_RTF_COMPRESSED`, and what that
// decompresses to is normally not RTF but the original HTML encapsulated in
// RTF control words. So the body is classified after decompression and only
// then turned into a part — and a genuinely rich-text body is handed on as
// `application/rtf` rather than rendered here.

import Foundation

/// Errors that can occur while parsing a `.msg` file.
public enum MSGParserError: Error, LocalizedError {
    case notACompoundFile
    case malformedContainer(String)
    case malformedRTF(String)

    public var errorDescription: String? {
        switch self {
            case .notACompoundFile:
                return "The data is not an Outlook .msg (OLE2 compound file) container"
            case .malformedContainer(let detail):
                return "Malformed .msg container: \(detail)"
            case .malformedRTF(let detail):
                return "Malformed compressed RTF body: \(detail)"
        }
    }
}

/// Parses Outlook `.msg` data into SwiftMail model types.
public struct MSGParser {

    /// How deep embedded messages are followed before the parser stops.
    /// Forwarded mail nests a few levels in practice; a crafted file could
    /// nest without limit.
    private static let maximumNestingDepth = 8

    /// `ATT_MHTML_REF` in `PR_ATTACH_FLAGS`: the body refers to this
    /// attachment by Content-ID, so it renders inline rather than being saved.
    private static let attachmentReferencedInBody: Int32 = 0x0000_0004

    // MARK: - Public API

    /// Parse Outlook `.msg` data into a ``Message``.
    ///
    /// The returned message uses `SequenceNumber(0)` and `nil` UID because the
    /// data does not originate from an IMAP session.
    ///
    /// - Parameter data: The contents of a `.msg` file.
    /// - Returns: A fully populated ``Message``.
    public static func parse(_ data: Data) throws -> Message {
        let file = try CompoundFile(data: data)
        let storage = MAPIStorage(file: file, entry: file.root, isTopLevel: true)

        let info = messageInfo(from: storage)
        let parts = parts(from: storage, sectionPath: [], depth: 0)

        var header = info
        header.parts = parts
        return Message(header: header, parts: parts)
    }

    // MARK: - Envelope

    /// Build the envelope, preferring the original transport headers.
    ///
    /// `PR_TRANSPORT_MESSAGE_HEADERS` usually holds the received headers whole,
    /// so the existing RFC 5322 parsing produces a better answer than
    /// reassembling addresses and dates from MAPI properties — encoded words,
    /// group syntax and time zones are already handled there. MAPI fills only
    /// what the headers did not supply, which is everything for a message that
    /// never crossed a transport (a draft, or a Sent item on some servers).
    static func messageInfo(from storage: MAPIStorage) -> MessageInfo {
        var info: MessageInfo
        if let headerBlock = storage.string(.transportMessageHeaders), !headerBlock.isEmpty {
            info = EMLParser.buildMessageInfo(from: EMLParser.parseHeaders(headerBlock))
        } else {
            info = MessageInfo(
                sequenceNumber: SequenceNumber(0),
                uid: nil,
                subject: nil,
                from: nil,
                to: [],
                cc: [],
                bcc: [],
                date: nil,
                messageId: nil,
                flags: [],
                parts: []
            )
        }

        if info.subject?.isEmpty ?? true {
            info.subject = storage.string(.subject) ?? storage.string(.normalizedSubject)
        }
        if info.from?.isEmpty ?? true {
            info.from = senderAddress(from: storage)
        }
        if info.date == nil {
            info.date = storage.date(.clientSubmitTime) ?? storage.date(.messageDeliveryTime)
        }
        if info.messageId == nil, let identifier = storage.string(.internetMessageID) {
            info.messageId = MessageID(identifier)
        }

        // Recipients carry real addresses; PR_DISPLAY_TO/CC hold display names
        // only, so they are the last resort.
        let recipients = self.recipients(from: storage)
        if info.to.isEmpty {
            info.to = recipients.to.isEmpty ? splitDisplayList(storage.string(.displayTo)) : recipients.to
        }
        if info.cc.isEmpty {
            info.cc = recipients.cc.isEmpty ? splitDisplayList(storage.string(.displayCc)) : recipients.cc
        }
        if info.bcc.isEmpty {
            info.bcc = recipients.bcc.isEmpty ? splitDisplayList(storage.string(.displayBcc)) : recipients.bcc
        }

        return info
    }

    /// The sender, preferring the SMTP address over the MAPI-internal one.
    ///
    /// Inside an Exchange organization `PR_SENDER_EMAIL_ADDRESS` is an X.500
    /// distinguished name (`/O=…/OU=…/CN=…`), which is not an address any
    /// downstream consumer can use, so it is taken only when nothing else
    /// names an SMTP address.
    private static func senderAddress(from storage: MAPIStorage) -> String? {
        let name = storage.string(.senderName) ?? storage.string(.sentRepresentingName)
        let address = storage.string(.senderSMTPAddress)
            ?? storage.string(.sentRepresentingSMTPAddress)
            ?? nonX500(storage.string(.senderEmailAddress))
            ?? nonX500(storage.string(.sentRepresentingEmailAddress))

        return format(name: name, address: address)
    }

    /// The recipients of a message, split by the field they were addressed in.
    struct Recipients {
        var to: [String] = []
        var cc: [String] = []
        var bcc: [String] = []
    }

    private static func recipients(from storage: MAPIStorage) -> Recipients {
        var recipients = Recipients()

        for recipient in storage.subStorages(prefix: "__recip_version1.0_") {
            let name = recipient.string(.displayName)
            let address = recipient.string(.smtpAddress) ?? nonX500(recipient.string(.emailAddress))
            guard let formatted = format(name: name, address: address) else { continue }

            // PR_RECIPIENT_TYPE: 1 = To, 2 = Cc, 3 = Bcc.
            switch recipient.int32(.recipientType) {
                case 2: recipients.cc.append(formatted)
                case 3: recipients.bcc.append(formatted)
                default: recipients.to.append(formatted)
            }
        }
        return recipients
    }

    /// Drop an Exchange X.500 distinguished name, which is not an address.
    private static func nonX500(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value.hasPrefix("/") || value.uppercased().hasPrefix("EX:") ? nil : value
    }

    private static func format(name: String?, address: String?) -> String? {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = address?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (name, address) {
            case let (name?, address?) where !name.isEmpty && !address.isEmpty:
                return name == address ? address : "\(name) <\(address)>"
            case let (_, address?) where !address.isEmpty:
                return address
            case let (name?, _) where !name.isEmpty:
                return name
            default:
                return nil
        }
    }

    /// `PR_DISPLAY_TO` and friends are a semicolon-separated list of display
    /// names, not addresses; they are split but never parsed as addr-specs.
    private static func splitDisplayList(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value
            .split(whereSeparator: { $0 == ";" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Parts

    /// Build the body and attachment parts of one message storage.
    ///
    /// Parts are numbered sequentially within `sectionPath`, so an embedded
    /// message's own parts land under its section the way a `message/rfc822`
    /// part's children do in an `.eml`.
    static func parts(from storage: MAPIStorage, sectionPath: [Int], depth: Int) -> [MessagePart] {
        var parts: [MessagePart] = []
        var next = 1

        func section() -> Section {
            defer { next += 1 }
            return Section(sectionPath + [next])
        }

        if let text = storage.string(.body), !text.isEmpty {
            parts.append(MessagePart(
                section: section(),
                contentType: "text/plain; charset=utf-8",
                encoding: "8bit",
                data: Data(text.utf8)
            ))
        }

        if let rich = richBodyPart(from: storage, section: section) {
            parts.append(rich)
        }

        for attachment in storage.subStorages(prefix: "__attach_version1.0_") {
            parts.append(contentsOf: attachmentParts(attachment, section: section(), depth: depth))
        }

        return parts
    }

    /// The rich body, in whichever representation the file carries.
    ///
    /// `section` is only called when a part is actually produced, so a body
    /// that turns out to be a duplicate does not consume a section number.
    private static func richBodyPart(from storage: MAPIStorage, section: () -> Section) -> MessagePart? {
        // A real HTML stream is rare in files Outlook writes, but when it is
        // there it is the original markup and needs no recovery.
        if let html = storage.data(.bodyHTML) ?? storage.string(.bodyHTML).map({ Data($0.utf8) }), !html.isEmpty {
            return MessagePart(
                section: section(),
                contentType: "text/html; charset=utf-8",
                encoding: "8bit",
                data: html
            )
        }

        guard let compressed = storage.data(.rtfCompressed),
              let rtf = try? RTFCompression.decompress(compressed), !rtf.isEmpty else { return nil }

        switch RTFDeencapsulation.flavour(of: rtf) {
            case .encapsulatedHTML:
                let html = RTFDeencapsulation.html(from: rtf)
                guard !html.isEmpty else { return nil }
                return MessagePart(
                    section: section(),
                    contentType: "text/html; charset=utf-8",
                    encoding: "8bit",
                    data: Data(html.utf8)
                )

            case .encapsulatedText:
                // Encapsulated plain text duplicates PR_BODY, which is already
                // a part; a second copy would only confuse consumers picking a
                // body to display.
                return nil

            case .rtf:
                // Genuinely rich text. SwiftMail does not render RTF, so the
                // bytes are handed on with an honest content type.
                return MessagePart(
                    section: section(),
                    contentType: "application/rtf",
                    disposition: "inline",
                    data: rtf
                )
        }
    }

    /// Turn one attachment storage into its part (and, for an embedded
    /// message, that message's parts underneath it).
    private static func attachmentParts(_ attachment: MAPIStorage, section: Section, depth: Int) -> [MessagePart] {
        let filename = attachment.string(.attachLongFilename) ?? attachment.string(.attachFilename)
        // Content-ID arrives with or without the angle brackets depending on
        // the producer; parts elsewhere in SwiftMail hold the bare token.
        let contentID = attachment.string(.attachContentID)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }
            .flatMap { $0.isEmpty ? nil : $0 }

        let method = attachment.int32(.attachMethod).flatMap { MAPIAttachMethod(rawValue: $0) }

        if method == .embeddedMessage, let embedded = attachment.embeddedMessage, depth < maximumNestingDepth {
            // A forwarded message: no filename and no byte stream, so it
            // becomes a message/rfc822 part carrying the nested envelope, with
            // the nested message's own parts numbered below it.
            let info = messageInfo(from: embedded)
            let part = MessagePart(
                section: section,
                contentType: "message/rfc822",
                disposition: "attachment",
                filename: filename ?? info.subject.map { "\($0).msg" },
                contentId: contentID,
                embeddedMessageInfo: info
            )
            let nested = parts(from: embedded, sectionPath: section.components, depth: depth + 1)
            return [part] + nested
        }

        guard let data = attachment.data(.attachData) else { return [] }

        // Outlook gives almost every attachment a Content-ID, so the ID alone
        // does not mean the body references it. `ATT_MHTML_REF` in
        // PR_ATTACH_FLAGS is the property that does, and without it an
        // attachment is a file the reader is meant to save — a PDF with a
        // stray Content-ID would otherwise vanish from `Message.attachments`.
        let referencedByBody = (attachment.int32(.attachFlags) ?? 0) & Self.attachmentReferencedInBody != 0
        let disposition = attachment.string(.attachContentDisposition)?
            .split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            ?? (referencedByBody ? "inline" : "attachment")

        return [MessagePart(
            section: section,
            contentType: attachment.string(.attachMIMETag) ?? "application/octet-stream",
            disposition: disposition,
            filename: filename,
            contentId: contentID,
            size: data.count,
            data: data
        )]
    }
}

// MARK: - Message convenience initializer

public extension Message {
    /// Initialize a Message by parsing an Outlook `.msg` container.
    ///
    /// - Parameter msgData: The contents of a `.msg` file.
    /// - Throws: ``MSGParserError`` if the container cannot be read.
    init(msgData: Data) throws {
        self = try MSGParser.parse(msgData)
    }
}
