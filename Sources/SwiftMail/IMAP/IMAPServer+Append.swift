import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

// MARK: - Append Commands

extension IMAPServer {
    /// Append a raw RFC 822 message to a mailbox.
    ///
    /// - Parameters:
    ///   - rawMessage: The complete RFC 822 message as a string.
    ///   - mailbox: The destination mailbox path (e.g. "Sent").
    ///   - flags: Flags to set on the appended message.
    ///   - internalDate: Optional internal date to store on the server.
    /// - Returns: ``AppendResult`` describing server-assigned identifiers.
    @discardableResult
    public func append(
        rawMessage: String,
        to mailbox: String,
        flags: [Flag],
        internalDate: Date?
    ) async throws -> AppendResult {
        try await append(rawMessage: Data(rawMessage.utf8), to: mailbox, flags: flags, internalDate: internalDate)
    }

    /// Append a raw RFC 822 message to a mailbox, byte for byte.
    ///
    /// For a message whose bytes are not valid UTF-8 — an 8-bit body in Latin-1, say — which the
    /// `String` variant cannot carry unchanged.
    ///
    /// - Parameters:
    ///   - rawMessage: The complete RFC 822 message as it should arrive on the server.
    ///   - mailbox: The destination mailbox path (e.g. "Sent").
    ///   - flags: Flags to set on the appended message.
    ///   - internalDate: Optional internal date to store on the server.
    /// - Returns: ``AppendResult`` describing server-assigned identifiers.
    @discardableResult
    public func append(
        rawMessage: Data,
        to mailbox: String,
        flags: [Flag],
        internalDate: Date?
    ) async throws -> AppendResult {
        if let limit = capabilities.globalAppendLimit, rawMessage.count > limit {
            throw IMAPError.appendLimitExceeded(rawMessage.count, limit)
        }
        let serverDate = internalDate.flatMap(makeInternalDate(from:))
        let command = AppendCommand(
            mailboxName: resolveMailboxPath(mailbox),
            message: rawMessage,
            flags: flags,
            internalDate: serverDate
        )
        return try await executeCommand(command)
    }

    /**
     Append a fully composed email to a mailbox.

     This helper builds the MIME body using ``Email/constructContent(use8BitMIME:includeBccHeader:)``
     and streams it to the server using the IMAP `APPEND` command. An appended
     message is a copy the sender keeps (a draft, a Sent copy), so it names its
     BCC recipients in a `Bcc` header; otherwise a draft would lose them. For
     a mailbox other people read (a shared folder), append the content of
     ``Email/constructContent(use8BitMIME:includeBccHeader:)`` without the
     header through ``append(rawMessage:to:flags:internalDate:)`` instead,
     ending it with a CRLF as this method does.

     The header fields get the check ``SMTPServer/sendEmail(_:)`` makes: a field
     name that is not an RFC 5322 field name, a `Bcc` or `Resent-Bcc` field in
     ``Email/additionalHeaders``, or a line break in a value that is not a fold
     throws ``IMAPError/invalidArgument(_:)`` and nothing is appended.

     - Parameters:
        - email: The email to append.
        - mailbox: The destination mailbox path (e.g. "Sent").
        - flags: Optional message flags to set during append.
        - internalDate: Optional internal date to store on the server. Defaults to the server-provided date.
     - Returns: ``AppendResult`` describing server-assigned identifiers.
     */
    @discardableResult
    public func append(
        email: Email,
        to mailbox: String,
        flags: [Flag] = [],
        internalDate: Date? = nil
    ) async throws -> AppendResult {
        guard !mailbox.isEmpty else {
            throw IMAPError.invalidArgument("Mailbox name must not be empty")
        }

        var content = canonicalizeCRLF(try email.keptCopyContent(use8BitMIME: true))
        if !content.hasSuffix("\r\n") {
            content.append("\r\n")
        }

        return try await append(rawMessage: content, to: mailbox, flags: flags, internalDate: internalDate)
    }

    /**
     Create a brand-new draft message by appending the provided email to the drafts mailbox.

     The method automatically sets the `\\Draft` flag and relies on the server's drafts mailbox if no
     custom mailbox is supplied. The draft names its BCC recipients in a `Bcc` header, so a
     client that resumes it keeps them; ``sendDraft(uid:via:from:to:)`` removes the header from
     the copy it delivers.

     - Parameters:
        - email: The email content to store as a draft.
        - mailbox: Optional custom mailbox path. Defaults to the detected drafts mailbox.
        - date: Optional internal date to stamp on the message.
        - additionalFlags: Extra flags to include alongside `\\Draft`.
     - Returns: ``AppendResult`` describing server-assigned identifiers.
     */
    @discardableResult
    public func createDraft(
        from email: Email,
        in mailbox: String? = nil,
        date: Date? = nil,
        additionalFlags: [Flag] = []
    ) async throws -> AppendResult {
        var flags: [Flag] = [.draft]
        flags.append(contentsOf: additionalFlags)

        let targetMailbox: String
        if let mailbox {
            targetMailbox = mailbox
        } else {
            targetMailbox = try draftsFolder.name
        }

        // Mark as a draft so mail clients (e.g. Apple Mail) recognize ownership
        // and remove the message from Drafts after sending.
        var draft = email
        var headers = draft.additionalHeaders ?? [:]
        if headers["X-Uniform-Type-Identifier"] == nil {
            headers["X-Uniform-Type-Identifier"] = "com.apple.mail-draft"
        }
        draft.additionalHeaders = headers

        return try await append(email: draft, to: targetMailbox, flags: flags, internalDate: date)
    }

    // MARK: - Append Helpers

    func makeInternalDate(from date: Date) -> ServerMessageDate? {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone.current
        calendar.timeZone = timeZone

        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard
            let year = components.year,
            let month = components.month,
            let day = components.day,
            let hour = components.hour,
            let minute = components.minute
        else {
            return nil
        }

        let second = components.second ?? 0
        let zoneMinutes = timeZone.secondsFromGMT(for: date) / 60

        guard let serverComponents = ServerMessageDate.Components(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second,
            timeZoneMinutes: zoneMinutes
        ) else {
            return nil
        }

        return ServerMessageDate(serverComponents)
    }
}
