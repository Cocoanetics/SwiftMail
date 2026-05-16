// SMTPServer+Send.swift
// Email and raw-message sending (MAIL FROM, RCPT TO, DATA) for SMTPServer.

import Foundation

public extension SMTPServer {
    /**
     Send an email with the server

     This method handles the complete email sending process:
     1. Validates the connection state
     2. Processes all recipients (To, CC, BCC)
     3. Handles attachments and inline content
     4. Uses 8BITMIME if supported by the server

     - Parameters:
       - email: The email to send, including recipients, subject, body, and attachments
     - Throws:
       - `SMTPError.connectionFailed` if not connected
       - `SMTPError.sendFailed` if the email cannot be sent
       - `SMTPError.recipientRejected` if any recipient is rejected
     - Note:
       - Logs email sending at info level with recipient count
       - Logs attachment details at debug level
       - Redacts sensitive content in logs
     */
    func sendEmail(_ email: Email) async throws {
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

        logger.debug("Sending email to \(allRecipients.count) recipients with subject: \(email.subject)")
        if !email.regularAttachments.isEmpty || !email.inlineAttachments.isEmpty {
            let attachmentMessage = "Email contains \(email.regularAttachments.count) regular attachments "
                + "and \(email.inlineAttachments.count) inline attachments"
            logger.debug("\(attachmentMessage)")
        }

        let preparedEmail = try Self.prepareEmailForSend(email, capabilities: capabilities)

        if preparedEmail.use8BitMIME {
            logger.debug("Server supports 8BITMIME, using it for this email")
        }

        do {
            // Create Mail From command using 8BITMIME if supported
            let mailFrom = try MailFromCommand(
                senderAddress: email.sender.address,
                use8BitMIME: preparedEmail.use8BitMIME,
                messageSizeOctets: preparedEmail.mailFromMessageSizeOctets
            )
            _ = try await executeCommand(mailFrom)

            // RCPT TO commands
            for recipient in allRecipients {
                let rcptTo = try RcptToCommand(recipientAddress: recipient.address)
                _ = try await executeCommand(rcptTo)
            }

            // DATA command
            let data = DataCommand()
            _ = try await executeCommand(data)

            // Send content
            let sendContent = SendContentCommand(data: preparedEmail.contentData)
            try await executeCommand(sendContent)

            logger.debug("Email sent successfully")
        } catch {
            logger.error("Failed to send email: \(error)")
            throw error
        }
    }

    /// Send a pre-built RFC 822 message (e.g., a draft fetched from IMAP).
    ///
    /// Unlike ``sendEmail(_:)`` which constructs the MIME body from an ``Email``
    /// struct, this method transmits an already-formatted message verbatim as raw bytes.
    ///
    /// - Parameters:
    ///   - rawMessage: The complete RFC 822 message as `Data`.
    ///   - sender: Sender address used for the SMTP `MAIL FROM` command.
    ///   - recipients: Recipient addresses used for `RCPT TO` commands.
    /// - Throws:
    ///   - `SMTPError.connectionFailed` if not connected.
    ///   - `SMTPError.sendFailed` if the server rejects the message.
    func sendRawMessage(
        _ rawMessage: Data,
        from sender: EmailAddress,
        to recipients: [EmailAddress]
    ) async throws {
        guard channel != nil else {
            throw SMTPError.connectionFailed("Not connected to SMTP server. Call connect() first.")
        }

        guard !recipients.isEmpty else {
            throw SMTPError.sendFailed("At least one recipient is required")
        }

        let use8BitMIME = supports8BitMIME

        // Check for 8-bit content if server doesn't support 8BITMIME
        if !use8BitMIME, rawMessage.contains(where: { $0 > 127 }) {
            throw SMTPError.sendFailed("Message contains 8-bit content but server does not support 8BITMIME")
        }

        do {
            let mailFrom = try MailFromCommand(
                senderAddress: sender.address,
                use8BitMIME: use8BitMIME
            )
            _ = try await executeCommand(mailFrom)

            for recipient in recipients {
                let rcptTo = try RcptToCommand(recipientAddress: recipient.address)
                _ = try await executeCommand(rcptTo)
            }

            let data = DataCommand()
            _ = try await executeCommand(data)

            // Send raw bytes directly without UTF-8 conversion
            let sendContent = SendContentCommand(data: rawMessage)
            try await executeCommand(sendContent)

            logger.debug("Raw message sent successfully")
        } catch {
            logger.error("Failed to send raw message: \(error)")
            throw error
        }
    }

    internal static func prepareEmailForSend(_ email: Email, capabilities: [String]) throws -> PreparedEmailForSend {
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
