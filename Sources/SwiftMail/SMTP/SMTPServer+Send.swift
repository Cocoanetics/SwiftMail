// SMTPServer+Send.swift
// Email and raw-message sending (MAIL FROM, RCPT TO, DATA) for SMTPServer.

import Foundation
import NIO
import NIOCore

extension SMTPServer {
    /**
     Send an email with the server

     This method handles the complete email sending process:
     1. Validates the connection state and recipients
     2. Processes all recipients (To, CC, BCC)
     3. Handles attachments and inline content
     4. Uses 8BITMIME if supported by the server
     5. Performs the `MAIL FROM` → `RCPT TO` → `DATA` → content dialogue

     Recipient handling is all-or-nothing: the first rejected `RCPT TO` aborts
     the transaction (with a best-effort `RSET`) and the message is transmitted
     to no recipient. The rejected address is reported via
     ``SMTPSendError/rejectedRecipient``.

     - Parameter email: The email to send, including recipients, subject, body, and attachments
     - Returns: An ``SMTPSendResult`` carrying the server's final accepting 2xx reply
     - Throws:
       - ``SMTPSendError`` for every failure once the SMTP mail transaction has
         started (`MAIL FROM` dispatched). Its ``SMTPSendError/phase-swift.property``,
         ``SMTPSendError/acceptance-swift.property`` and
         ``SMTPSendError/retryDisposition-swift.property`` distinguish retryable,
         permanent, and unsafe-to-retry outcomes without parsing error strings.
       - ``SMTPError`` for failures before the dialogue starts: not connected,
         no recipients, an invalid address, or a message exceeding the
         server-advertised `SIZE` limit. These are proven pre-submission
         failures and can follow normal retry policy.
       - `CancellationError` if the task is cancelled before the dialogue starts.
     - Note:
       - All public operations on one ``SMTPServer`` are queued so commands,
         authentication, connection changes, and submissions cannot interleave.
       - After an explicit server rejection the connection stays usable for
         another attempt. After a timeout, cancellation, connection loss, or
         any ambiguous outcome the connection is closed; call ``connect()``
         (and authenticate) again first.
       - Logs email sending at debug level and redacts sensitive content in logs
     */
    @discardableResult
    public func sendEmail(_ email: Email) async throws -> SMTPSendResult {
        let permit = try await operationGate.acquire()
        defer { operationGate.release(permit) }

        // Check if we have a valid channel (meaning we're connected)
        guard channel != nil else {
            logger.error("Attempting to send email without an active connection")
            throw SMTPError.connectionFailed("Not connected to SMTP server. Call connect() first.")
        }

        // We don't explicitly check for authentication here, as the SMTP server will reject
        // commands if not authenticated, and that will be handled by the error handling below.

        var allRecipients = email.recipients
        allRecipients.append(contentsOf: email.ccRecipients)
        allRecipients.append(contentsOf: email.bccRecipients)

        guard !allRecipients.isEmpty else {
            throw SMTPError.sendFailed("At least one recipient is required")
        }

        logger.debug("Sending email to \(allRecipients.count) recipients with subject: \(email.subject)")
        if !email.regularAttachments.isEmpty || !email.inlineAttachments.isEmpty {
            let attachmentMessage = "Email contains \(email.regularAttachments.count) regular attachments "
                + "and \(email.inlineAttachments.count) inline attachments"
            logger.debug("\(attachmentMessage)")
        }

        let preparedEmail = try Self.prepareEmailForSend(email, capabilities: capabilities)

        if preparedEmail.use8BitMIME {
            self.logger.debug("Server supports 8BITMIME, using it for this email")
        }

        // Create Mail From command using 8BITMIME if supported
        let mailFrom = try MailFromCommand(
            senderAddress: email.sender.address,
            use8BitMIME: preparedEmail.use8BitMIME,
            messageSizeOctets: preparedEmail.mailFromMessageSizeOctets
        )

        let result = try await performSubmission(
            mailFrom: mailFrom,
            recipients: allRecipients,
            contentData: preparedEmail.contentData,
            holding: permit
        )

        self.logger.debug("Email sent successfully")
        return result
    }

    /// Send a pre-built RFC 822 message (e.g., a draft fetched from IMAP).
    ///
    /// Unlike ``sendEmail(_:)`` which constructs the MIME body from an ``Email``
    /// struct, this method transmits an already-formatted message verbatim as raw bytes.
    ///
    /// Recipient handling is all-or-nothing: the first rejected `RCPT TO` aborts
    /// the transaction (with a best-effort `RSET`) and the message is transmitted
    /// to no recipient.
    ///
    /// - Parameters:
    ///   - rawMessage: The complete RFC 822 message as `Data`.
    ///   - sender: Sender address used for the SMTP `MAIL FROM` command.
    ///   - recipients: Recipient addresses used for `RCPT TO` commands.
    /// - Returns: An ``SMTPSendResult`` carrying the server's final accepting 2xx reply.
    /// - Throws:
    ///   - ``SMTPSendError`` for every failure once the SMTP mail transaction has
    ///     started (`MAIL FROM` dispatched); see ``sendEmail(_:)`` for the contract.
    ///   - ``SMTPError`` for failures before the dialogue starts: not connected,
    ///     no recipients, an invalid address, or 8-bit content without server
    ///     `8BITMIME` support.
    ///   - `CancellationError` if the task is cancelled before the dialogue starts.
    @discardableResult
    public func sendRawMessage(
        _ rawMessage: Data,
        from sender: EmailAddress,
        to recipients: [EmailAddress]
    ) async throws -> SMTPSendResult {
        let permit = try await operationGate.acquire()
        defer { operationGate.release(permit) }

        guard channel != nil else {
            throw SMTPError.connectionFailed("Not connected to SMTP server. Call connect() first.")
        }

        guard !recipients.isEmpty else {
            throw SMTPError.sendFailed("At least one recipient is required")
        }

        let use8BitMIME = supports8BitMIME

        // Check for 8-bit content if server doesn't support 8BITMIME
        if !use8BitMIME && rawMessage.contains(where: { $0 > 127 }) {
            throw SMTPError.sendFailed("Message contains 8-bit content but server does not support 8BITMIME")
        }

        let mailFrom = try MailFromCommand(
            senderAddress: sender.address,
            use8BitMIME: use8BitMIME
        )

        // Raw bytes are transmitted directly without UTF-8 conversion
        let result = try await performSubmission(
            mailFrom: mailFrom,
            recipients: recipients,
            contentData: rawMessage,
            holding: permit
        )

        logger.debug("Raw message sent successfully")
        return result
    }

    /**
     Abort the current mail transaction with the SMTP `RSET` command (RFC 5321 §4.1.1.5)

     RSET discards any sender, recipients, and mail data accumulated in the
     current transaction and returns the session to the state right after EHLO.
     ``sendEmail(_:)`` and ``sendRawMessage(_:from:to:)`` already reset a
     rejected transaction automatically; call this directly if you drive parts
     of the dialogue yourself or want to prove the session is in a clean state.

     - Returns: The server's `250` reply.
     - Throws:
       - `SMTPError.connectionFailed` if not connected.
       - `SMTPError.unexpectedResponse` if the server refuses the reset.
     */
    @discardableResult
    public func reset() async throws -> SMTPResponse {
        let permit = try await operationGate.acquire()
        defer { operationGate.release(permit) }

        guard channel != nil else {
            throw SMTPError.connectionFailed("Not connected to SMTP server. Call connect() first.")
        }

        return try await executeCommand(RsetCommand(), holding: permit)
    }

    // MARK: - Shared submission dialogue

    /// Run one complete mail transaction and classify every failure.
    ///
    /// Both public send entry points funnel through here. Error contract: once
    /// `MAIL FROM` has been dispatched, every thrown error is an ``SMTPSendError``;
    /// anything thrown earlier (invalid addresses, cancellation before the
    /// dialogue) is a plain error and provably pre-submission.
    private func performSubmission(
        mailFrom: MailFromCommand,
        recipients: [EmailAddress],
        contentData: Data,
        holding permit: SMTPOperationGate.Permit
    ) async throws -> SMTPSendResult {
        // Build every RCPT TO up front so address-validation failures surface
        // as plain SMTPError before any part of the dialogue is dispatched.
        let rcptCommands: [(command: RcptToCommand, recipient: EmailAddress)] = try recipients.map {
            (try RcptToCommand(recipientAddress: $0.address), $0)
        }

        // Nothing dispatched yet: a cancellation here stays a plain CancellationError.
        try Task.checkCancellation()

        do {
            _ = try await executeSubmissionCommand(
                mailFrom,
                holding: permit,
                writeTimeout: submissionTimeouts.mailFromResponse,
                responseTimeout: submissionTimeouts.mailFromResponse
            )
        } catch {
            throw await abortSubmission(
                with: .classifyingProvenNonAcceptance(error, phase: .mailFrom),
                holding: permit
            )
        }

        // All-or-nothing recipient policy: the first rejection aborts the
        // transaction instead of continuing with a partial recipient set.
        for (command, recipient) in rcptCommands {
            do {
                _ = try await executeSubmissionCommand(
                    command,
                    holding: permit,
                    writeTimeout: submissionTimeouts.recipientResponse,
                    responseTimeout: submissionTimeouts.recipientResponse
                )
            } catch {
                throw await abortSubmission(
                    with: .classifyingProvenNonAcceptance(error, phase: .rcptTo, recipient: recipient),
                    holding: permit
                )
            }
        }

        do {
            _ = try await executeSubmissionCommand(
                DataCommand(),
                holding: permit,
                writeTimeout: submissionTimeouts.dataResponse,
                responseTimeout: submissionTimeouts.dataResponse
            )
        } catch {
            throw await abortSubmission(
                with: .classifyingProvenNonAcceptance(error, phase: .data),
                holding: permit
            )
        }

        return try await performContentSubmission(contentData, holding: permit)
    }

    private func performContentSubmission(
        _ contentData: Data,
        holding permit: SMTPOperationGate.Permit
    ) async throws -> SMTPSendResult {
        // Last provably-safe abort point: no message byte has been handed to
        // the transport yet, so a cancellation here cannot cause a delivery.
        if Task.isCancelled {
            throw await abortSubmission(
                with: .classifyingProvenNonAcceptance(CancellationError(), phase: .content),
                holding: permit
            )
        }

        let dispatchState = SMTPSubmissionContentDispatchState()
        do {
            let response = try await executeSubmissionCommand(
                SendContentCommand(data: contentData),
                holding: permit,
                writeTimeout: submissionTimeouts.contentUpload,
                responseTimeout: submissionTimeouts.contentResponse,
                writeTimeoutStage: .contentUpload,
                responseTimeoutStage: .contentResponse,
                contentDispatchState: dispatchState
            )
            return SMTPSendResult(response: response)
        } catch {
            let sendError = SMTPSendError.classifyingContentFailure(
                error,
                endOfDataMayHaveBeenDispatched: dispatchState.endOfDataMayHaveBeenDispatched
            )
            throw await abortSubmission(with: sendError, holding: permit)
        }
    }

    /// Run the cleanup appropriate for a classified submission failure and
    /// return the error for the caller to throw.
    ///
    /// - An explicit rejection before the content terminator leaves the dialogue in sync: abort
    ///   the open transaction with a best-effort `RSET` (RFC 5321 §4.3.1
    ///   requires concluding a transaction before starting another) so the
    ///   connection stays reusable; close it if the reset fails.
    /// - An explicit final content rejection already concluded the transaction;
    ///   the session is back in command state and stays open.
    /// - A `421` reply announces the server is closing the channel: close ours.
    /// - Everything else (timeout, cancellation, connection loss, transport
    ///   errors) leaves the dialogue state unknown — possibly even DATA-input
    ///   mode, where an `RSET` would be swallowed as message text — so the
    ///   connection is closed.
    private func abortSubmission(
        with sendError: SMTPSendError,
        holding permit: SMTPOperationGate.Permit
    ) async -> SMTPSendError {
        logger.error("\(sendError.description)")

        // Any ambiguous outcome leaves the protocol state unknown. This also
        // covers an unexpected non-final reply after the content terminator:
        // even though a reply arrived, it did not prove that the server
        // accepted or rejected the completed message.
        if sendError.acceptance == .ambiguous {
            await closeConnectionAfterFailedSubmission(holding: permit)
            return sendError
        }

        switch sendError.reason {
            case .reply(let response) where response.code == 421:
                await closeConnectionAfterFailedSubmission(holding: permit)
            case .reply where sendError.phase == .content:
                break
            case .reply:
                do {
                    _ = try await executeCommand(RsetCommand(), holding: permit)
                } catch {
                    logger.warning("RSET after rejected transaction failed: \(error)")
                    await closeConnectionAfterFailedSubmission(holding: permit)
                }
            case .cancelled, .timedOut, .connectionLost, .transport:
                await closeConnectionAfterFailedSubmission(holding: permit)
        }

        return sendError
    }

    /// Close and clear the channel after a submission failure that leaves the
    /// session unusable. A later ``connect()`` starts a fresh session.
    private func closeConnectionAfterFailedSubmission(
        holding permit: SMTPOperationGate.Permit
    ) async {
        precondition(operationGate.isHeld(permit), "SMTP channel closed without owning it")
        guard let channel = self.channel else {
            return
        }

        self.channel = nil
        self.isTLSEnabled = false
        self.capabilities = []

        do {
            try await channel.close().get()
        } catch {
            logger.debug("Channel close after failed submission reported: \(error)")
        }
    }

    static func prepareEmailForSend(_ email: Email, capabilities: [String]) throws -> PreparedEmailForSend {
        let use8BitMIME = capabilities.contains("8BITMIME")
        let preparedContent = email.preparedContent(use8BitMIME: use8BitMIME)
        let maximumMessageSizeOctets = maximumMessageSizeOctets(from: capabilities)

        if let maximumMessageSizeOctets,
           preparedContent.messageSizeOctets > maximumMessageSizeOctets {
            throw SMTPError.messageTooLarge(
                messageSizeOctets: preparedContent.messageSizeOctets,
                maximumMessageSizeOctets: maximumMessageSizeOctets
            )
        }

        return PreparedEmailForSend(
            use8BitMIME: use8BitMIME,
            contentData: preparedContent.contentData,
            emailSizeOctets: preparedContent.messageSizeOctets,
            mailFromMessageSizeOctets: maximumMessageSizeOctets == nil ? nil : preparedContent.messageSizeOctets
        )
    }
}
