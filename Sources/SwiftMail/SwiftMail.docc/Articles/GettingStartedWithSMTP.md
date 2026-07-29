# Getting Started with SMTP

Learn how to use SwiftMail's SMTP functionality to send emails.

## Overview

The `SMTPServer` class provides a Swift-native interface for sending emails via SMTP servers. This guide will walk you through the basic steps of connecting to an SMTP server and sending emails.

## Creating an SMTP Server Instance

First, create an instance of `SMTPServer` with your server details:

```swift
import SwiftMail

let smtpServer = SMTPServer(host: "smtp.example.com", port: 587)
```

Common SMTP ports:
- 587: STARTTLS (recommended)
- 465: SSL/TLS
- 25: Unencrypted (not recommended)

## Connecting and Authentication

Connect to the server and authenticate with your credentials:

```swift
try await smtpServer.connect()
try await smtpServer.login(username: "user@example.com", password: "password")
```

## Creating and Sending Emails

Create an email message and send it:

```swift
// Create a new email
let message = Email()
message.from = "sender@example.com"
message.to = ["recipient@example.com"]
message.subject = "Hello from SwiftMail"
message.text = "This is a test email sent using SwiftMail."

// Send the email
try await smtpServer.send(message)
```

## Adding Attachments

You can add attachments to your emails:

```swift
let attachment = Attachment(
    filename: "document.pdf",
    mimeType: "application/pdf",
    data: fileData
)
message.attachments.append(attachment)
```

## Error Handling

SwiftMail uses Swift's error handling system. Failures before the SMTP mail
transaction starts — connectivity problems, authentication failures, invalid
addresses, oversized messages — surface as ``SMTPError`` and can follow your
normal retry policy.

Once the transaction has started, ``SMTPServer/sendEmail(_:)`` and
``SMTPServer/sendRawMessage(_:from:to:)`` throw ``SMTPSendError``, which
classifies the outcome so a durable outbox can make safe retry decisions
without parsing error strings:

```swift
do {
    let result = try await smtpServer.sendEmail(email)
    print("Accepted: \(result.response.code) \(result.response.message)")
} catch let error as SMTPSendError {
    switch error.retryDisposition {
    case .retryable:
        // The server provably did not accept the message — requeue it.
        break
    case .permanent:
        // Explicitly rejected with a permanent error — do not retry.
        break
    case .unsafeToRetry:
        // The message content was transmitted but no clear final reply
        // arrived. The server may have accepted it; retrying automatically
        // could deliver the email twice. Reconcile out of band first.
        break
    }
} catch {
    // Failed before the dialogue started — normal retry policy applies.
    print("SMTP error: \(error)")
}
```

An ``SMTPSendError`` also reports the ``SMTPSendError/phase-swift.property``
the dialogue reached, what is known about the server's
``SMTPSendError/acceptance-swift.property`` of the message, the explicit
server ``SMTPSendError/response`` when one was received, and the
``SMTPSendError/rejectedRecipient`` when a `RCPT TO` was refused.

## Next Steps

- Learn more about SMTP operations in <doc:SendingEmailsWithSMTP>
- Explore the ``SMTPServer`` API documentation
- Check out the demo apps in the repository

## Topics

- ``SMTPServer``
