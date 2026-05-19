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
    /// 3. Sends the raw message via the provided ``SMTPServer``.
    /// 4. Appends the message to the Sent folder with the `\Seen` flag and current date.
    /// 5. Marks the draft as `\Deleted` and expunges it (UID EXPUNGE when available).
    ///
    /// - Parameters:
    ///   - draftUID: UID of the draft message.
    ///   - smtp: A connected and authenticated ``SMTPServer``.
    ///   - draftMailbox: Source mailbox path. If `nil`, uses ``draftsFolder`` (throws if unavailable).
    ///   - sentMailbox: Destination mailbox path. If `nil`, uses ``sentFolder`` (throws if unavailable).
    /// - Returns: The UID of the message in the Sent folder, if the server supports UIDPLUS.
    /// - Throws: ``UndefinedFolderError`` if drafts/sent folders cannot be resolved and no explicit path is provided.
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
        let (sender, recipients) = try parseSendDraftAddresses(from: messageInfo)

        // 5. Send via SMTP
        try await smtp.sendRawMessage(rawMessageData, from: sender, to: recipients)

        // 6. Append to Sent folder with \Seen flag.
        let appendResult = try await appendDraftToSent(rawMessageData: rawMessageData, mailbox: resolvedSentMailbox)

        // 7. Delete the draft and expunge
        try await deleteAndExpungeDraft(draftUID: draftUID)

        return appendResult.firstUID
    }

    // MARK: - Send Draft Helpers

    /// Parse the sender and recipient addresses out of a draft's envelope info.
    private func parseSendDraftAddresses(
        from messageInfo: MessageInfo
    ) throws -> (sender: EmailAddress, recipients: [EmailAddress]) {
        guard let senderString = messageInfo.from else {
            throw IMAPError.invalidArgument("Draft has no sender address")
        }
        guard let sender = Self.parseEmailAddresses(from: senderString).first else {
            throw IMAPError.invalidArgument("Draft has invalid sender address")
        }

        var recipientStrings: [String] = []
        recipientStrings.append(contentsOf: messageInfo.to)
        recipientStrings.append(contentsOf: messageInfo.cc)
        recipientStrings.append(contentsOf: messageInfo.bcc)

        guard !recipientStrings.isEmpty else {
            throw IMAPError.invalidArgument("Draft has no recipients")
        }

        let recipients = recipientStrings.flatMap { Self.parseEmailAddresses(from: $0) }

        guard !recipients.isEmpty else {
            throw IMAPError.invalidArgument("Draft has no valid recipient addresses")
        }

        return (sender, recipients)
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

    /// Parse one or more email addresses from an envelope address string.
    ///
    /// Handles:
    /// - Simple addresses: `"email@example.com"`
    /// - Named addresses: `"Name <email@example.com>"`
    /// - RFC 2822 group syntax: `"Group Name: addr1@x.com, Name <addr2@y.com>;"`
    ///
    /// - Parameter addressString: The address string from IMAP ENVELOPE.
    /// - Returns: An array of ``EmailAddress`` values (may be empty for malformed input).
    static func parseEmailAddresses(from addressString: String) -> [EmailAddress] {
        let trimmed = addressString.trimmingCharacters(in: .whitespaces)

        // Check for RFC 2822 group syntax: "Group Name: addr1, addr2;"
        if let colonIndex = trimmed.firstIndex(of: ":"),
           trimmed.hasSuffix(";") {
            // Extract the address list between ":" and ";"
            let afterColon = trimmed.index(after: colonIndex)
            let beforeSemicolon = trimmed.index(trimmed.endIndex, offsetBy: -1)
            guard afterColon < beforeSemicolon else { return [] }

            let addressList = String(trimmed[afterColon..<beforeSemicolon])
            // Split by comma and parse each address
            return addressList
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { parseSingleEmailAddress(from: $0) }
        }

        // Single address
        return [parseSingleEmailAddress(from: trimmed)]
    }

    /// Parse a single address string like `"Name <email@example.com>"` or `"email@example.com"`
    /// into an ``EmailAddress``.
    static func parseSingleEmailAddress(from addressString: String) -> EmailAddress {
        let trimmed = addressString.trimmingCharacters(in: .whitespaces)

        // Try to extract "Name <address>" format
        if let angleBracketStart = trimmed.lastIndex(of: "<"),
           let angleBracketEnd = trimmed.lastIndex(of: ">"),
           angleBracketStart < angleBracketEnd {
            let address = String(trimmed[trimmed.index(after: angleBracketStart)..<angleBracketEnd])
                .trimmingCharacters(in: .whitespaces)
            let namePart = String(trimmed[trimmed.startIndex..<angleBracketStart])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            let name = namePart.isEmpty ? nil : namePart
            return EmailAddress(name: name, address: address)
        }

        // Plain address
        return EmailAddress(address: trimmed)
    }
}
