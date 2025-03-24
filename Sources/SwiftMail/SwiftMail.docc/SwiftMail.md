# ``SwiftMail``

A Swift package for comprehensive email functionality, providing robust IMAP and SMTP client implementations.

## Overview

SwiftMail is a powerful email package that enables you to work with email protocols in your Swift applications. Whether you need to fetch emails from a server or send new messages, SwiftMail provides an intuitive API to handle your email communication needs.

The package is organized into two main components:
- IMAP functionality for retrieving and managing emails
- SMTP functionality for sending emails

Core features include:
- Email address handling and formatting
- MIME content encoding and decoding
- Secure credential management
- Comprehensive logging system

```swift
import SwiftMail

// Create and configure an SMTP server connection
let smtpServer = SMTPServer(host: "smtp.example.com", port: 587)
try await smtpServer.connect()

// Send an email
let email = Email(
    sender: EmailAddress(address: "sender@example.com"),
    recipients: [EmailAddress(address: "recipient@example.com")],
    subject: "Hello from SwiftMail",
    body: "This is a test email sent using SwiftMail."
)
try await smtpServer.sendEmail(email)
```

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:Installation>

### Tutorials

- <doc:WorkingWithIMAP>
- <doc:SendingEmailsWithSMTP>

### Core Features

- ``IMAPServer``
- ``SMTPServer``
- ``Email``
- ``EmailAddress``
