import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

// MARK: - Send Draft Orchestration

extension IMAPServer {
    /// Send a draft message via SMTP and move it to the Sent folder.
    ///
    /// This method orchestrates the full send-draft workflow:
    /// 1. Resolves the drafts and sent mailboxes via special-use attributes (or throws if not found).
    /// 2. Selects the draft mailbox and fetches the raw message + envelope info.
    /// 3. Sends the raw message via the provided ``SMTPServer``, without its `Bcc` header.
    ///    A draft whose header holds a carriage return without a line feed is
    ///    not sent.
    /// 4. Appends the message, `Bcc` header included, to the Sent folder with the `\Seen` flag and current date.
    /// 5. Marks the draft as `\Deleted` and expunges it (UID EXPUNGE when available).
    ///
    /// - Parameters:
    ///   - draftUID: UID of the draft message.
    ///   - smtp: A connected and authenticated ``SMTPServer``.
    ///   - draftMailbox: Source mailbox path. If `nil`, uses ``draftsFolder`` (throws if unavailable).
    ///   - sentMailbox: Destination mailbox path. If `nil`, uses ``sentFolder`` (throws if unavailable).
    /// - Returns: The UID of the message in the Sent folder, if the server supports UIDPLUS.
    /// - Throws: ``UndefinedFolderError`` if drafts/sent folders cannot be resolved and no explicit path is provided;
    ///   ``IMAPError/invalidArgument(_:)`` if the draft cannot be sent as stored, which leaves it in place.
    @discardableResult
    public func sendDraft(
        uid draftUID: UID,
        via smtp: SMTPServer,
        from draftMailbox: String? = nil,
        to sentMailbox: String? = nil
    ) async throws -> UID? {
        // 1. Resolve mailbox paths via special-use attributes (or use explicit overrides)
        let resolvedDraftMailbox = try draftMailbox ?? draftsFolder.name
        let resolvedSentMailbox = try sentMailbox ?? sentFolder.name

        // 2. Select the drafts mailbox
        try await selectMailbox(resolvedDraftMailbox)

        // 3. Fetch raw message and envelope info
        let rawMessageData = try await fetchRawMessage(identifier: draftUID)

        guard let messageInfo = try await fetchMessageInfo(for: draftUID) else {
            throw IMAPError.fetchFailed("Could not fetch message info for draft UID \(draftUID.value)")
        }

        // 4. Extract sender and recipients from the envelope
        let (sender, recipients) = try Self.sendDraftAddresses(from: messageInfo)

        // 5. Send via SMTP. BCC recipients are envelope recipients only: the
        // draft names them in a Bcc header, which must not reach the people
        // the message is delivered to (RFC 5322 section 3.6.3).
        try await smtp.sendRawMessage(Self.removingBccFields(from: rawMessageData), from: sender, to: recipients)

        // 6. Append to Sent folder with \Seen flag.
        let appendResult = try await appendDraftToSent(rawMessageData: rawMessageData, mailbox: resolvedSentMailbox)

        // 7. Delete the draft and expunge
        try await deleteAndExpungeDraft(draftUID: draftUID)

        return appendResult.firstUID
    }

    // MARK: - Send Draft Helpers

    /// The sender and recipients of a draft, read from its envelope info.
    ///
    /// Each field may name several addresses and groups; group members are
    /// recipients like any other. The draft is rejected rather than sent to
    /// fewer people than it names when a recipient field holds text that is
    /// not an address.
    static func sendDraftAddresses(
        from messageInfo: MessageInfo
    ) throws -> (sender: EmailAddress, recipients: [EmailAddress]) {
        guard !messageInfo.fromAddresses.isEmpty else {
            throw IMAPError.invalidArgument("Draft has no sender address")
        }
        guard let sender = messageInfo.fromAddresses.mailboxes.first else {
            throw IMAPError.invalidArgument("Draft has invalid sender address")
        }

        let entries = messageInfo.toAddresses + messageInfo.ccAddresses + messageInfo.bccAddresses
        guard !entries.isEmpty else {
            throw IMAPError.invalidArgument("Draft has no recipients")
        }

        if case .invalid(let text) = entries.first(where: \.isInvalid) {
            throw IMAPError.invalidArgument("Draft has an invalid recipient address: \(text)")
        }

        let recipients = entries.mailboxes
        guard !recipients.isEmpty else {
            throw IMAPError.invalidArgument("Draft has no valid recipient addresses")
        }

        return (sender, recipients)
    }

    /// The message with every `Bcc` field removed from its header section,
    /// folded continuation lines included. The body and every other byte are
    /// kept as they are, so a message in any charset survives unchanged.
    ///
    /// - Throws: ``IMAPError/invalidArgument(_:)`` when a line of the header
    ///   section, the blank line that ends it included, does not end in CRLF:
    ///   a carriage return no line feed follows, or a line feed no carriage
    ///   return comes before (readers disagree on where such a line ends, so a
    ///   `Bcc` field could hide behind it); a `Resent-Bcc` field (`sendDraft` does not send resent
    ///   messages, and every recipient would see it), or a line it cannot tell
    ///   is or is not a `Bcc` field: a continuation line with no field above it,
    ///   or a field name that is empty or holds a byte RFC 5322 does not allow
    ///   in one. The draft is not sent and stays as it is. A line with no colon
    ///   and no continuation is kept: no reader takes it for a field.
    static func removingBccFields(from message: Data) throws -> Data {
        let bytes = [UInt8](message)
        let lineFeed: UInt8 = 0x0A
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        var dropping = false
        // Whether the last line that was not a continuation was a header field,
        // so a continuation line below it has a field to belong to.
        var inField = false
        var lineStart = 0
        while lineStart < bytes.count {
            let lineEnd = bytes[lineStart...].firstIndex(of: lineFeed).map { $0 + 1 } ?? bytes.count
            let line = bytes[lineStart..<lineEnd]
            let content = try Self.headerLineContent(line)
            if content.isEmpty {
                // The blank line ends the header section; the rest is the body.
                output.append(contentsOf: bytes[lineStart...])
                break
            }
            if let first = content.first, first == 0x20 || first == 0x09 {
                // A folded continuation belongs to the field above it. With no
                // field above it, unfolding could make it part of a Bcc field.
                guard inField else {
                    throw IMAPError.invalidArgument("Draft header has a continuation line with no field above it")
                }
            } else {
                (dropping, inField) = try Self.classifyFieldLine(content)
            }
            if !dropping {
                output.append(contentsOf: line)
            }
            lineStart = lineEnd
        }
        return Data(output)
    }

    /// A header line without its CRLF ending. The last line of a message with
    /// no blank line may have no ending at all.
    ///
    /// - Throws: ``IMAPError/invalidArgument(_:)`` for a line feed with no
    ///   carriage return before it, or a carriage return no line feed follows.
    private static func headerLineContent(_ line: ArraySlice<UInt8>) throws -> ArraySlice<UInt8> {
        let lineFeed: UInt8 = 0x0A
        let carriageReturn: UInt8 = 0x0D
        var content = line
        if content.last == lineFeed {
            content = content.dropLast()
            guard content.last == carriageReturn else {
                throw IMAPError.invalidArgument("Draft header has a line feed without a carriage return")
            }
            content = content.dropLast()
        }
        if content.contains(carriageReturn) {
            throw IMAPError.invalidArgument("Draft header has a carriage return without a line feed")
        }
        return content
    }

    /// Whether a header line that is not a continuation is a `Bcc` field, and
    /// whether it is a header field at all (so continuation lines may follow).
    /// A line with no colon is neither.
    ///
    /// - Throws: ``IMAPError/invalidArgument(_:)`` for a field name that is
    ///   empty or holds a byte RFC 5322 does not allow in one, and for a
    ///   `Resent-Bcc` field.
    private static func classifyFieldLine(_ content: ArraySlice<UInt8>) throws -> (isBcc: Bool, isField: Bool) {
        guard let name = Self.fieldName(content) else { return (false, false) }
        guard !name.isEmpty, name.allSatisfy({ (33...126).contains($0) }) else {
            throw IMAPError.invalidArgument("Draft header has a field name that is not valid")
        }
        if name == Array("resent-bcc".utf8) {
            throw IMAPError.invalidArgument("Draft has a Resent-Bcc field")
        }
        return (name == Array("bcc".utf8), true)
    }

    /// The field name of a header line, ASCII-lowercased, with any whitespace
    /// before the colon removed; nil for a line with no colon.
    private static func fieldName(_ line: ArraySlice<UInt8>) -> [UInt8]? {
        guard let colon = line.firstIndex(of: UInt8(ascii: ":")) else { return nil }
        var name = line[line.startIndex..<colon]
        while let last = name.last, last == 0x20 || last == 0x09 {
            name = name.dropLast()
        }
        return name.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
    }

    /// Append the raw draft message to the Sent mailbox with the `\Seen` flag.
    private func appendDraftToSent(rawMessageData: Data, mailbox: String) async throws -> AppendResult {
        // Raw messages may include non-UTF-8 bytes (Latin-1 etc.) that we still need to
        // preserve verbatim; lossy decoding keeps replacement chars rather than
        // dropping the message entirely.
        var rawMessageString = rawMessageData.lossyUTF8String
        rawMessageString = canonicalizeCRLF(rawMessageString)
        if !rawMessageString.hasSuffix("\r\n") {
            rawMessageString.append("\r\n")
        }

        return try await append(
            rawMessage: rawMessageString,
            to: mailbox,
            flags: [.seen],
            internalDate: Date()
        )
    }

    /// Mark the draft message as deleted and expunge it.
    private func deleteAndExpungeDraft(draftUID: UID) async throws {
        let draftUIDSet = UIDSet(draftUID)
        try await store(flags: [.deleted], on: draftUIDSet, operation: .add)

        if supportsUIDPlus {
            try await expunge(messages: draftUIDSet)
        } else {
            try await expunge()
        }
    }
}
