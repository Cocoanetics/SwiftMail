# SwiftMail

A Swift package for email functionality, including IMAP and SMTP clients.

## Overview

SwiftMail is a comprehensive email package that includes:

- **SwiftIMAP**: Library for interacting with IMAP servers
- **SwiftSMTP**: Library for sending emails via SMTP servers
- **SwiftMailCore**: Core functionality shared between email protocols

## Features

### SwiftIMAP
- Connect to IMAP servers securely using SSL/TLS
- Authenticate with username and password
- Select mailboxes and retrieve mailbox information
- Fetch email headers and message parts
- Handle MIME-encoded content and quoted-printable encoding

### SwiftSMTP
- Connect to SMTP servers with support for secure connections
- Support for both plain and SSL/TLS connections
- STARTTLS support for upgrading connections
- Authentication using PLAIN and LOGIN methods
- Send emails with attachments
- Properly formatted MIME content

### SwiftMailCore
- Shared networking utilities
- Email address handling and formatting
- Credential redaction for secure logging
- String and data utilities for email processing

## Command Line Demos

The package includes command line demos that showcase the functionality of both the IMAP and SMTP libraries:

- **SwiftIMAPCLI**: Demonstrates IMAP operations like listing mailboxes and fetching messages
- **SwiftSMTPCLI**: Demonstrates sending emails via SMTP

Both demos look for a `.env` file in the current working directory for configuration. Create a `.env` file with the following variables:

```
# IMAP Configuration
IMAP_HOST=imap.example.com
IMAP_PORT=993
IMAP_USER=your_username
IMAP_PASS=your_password

# SMTP Configuration
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USER=your_username
SMTP_PASS=your_password
```

To run the demos:

```bash
# Run the IMAP demo
swift run SwiftIMAPCLI

# Run the SMTP demo
swift run SwiftSMTPCLI

# Run with debug logging enabled (recommended for development)
ENABLE_DEBUG_OUTPUT=1 OS_ACTIVITY_DT_MODE=debug swift run SwiftIMAPCLI
ENABLE_DEBUG_OUTPUT=1 OS_ACTIVITY_DT_MODE=debug swift run SwiftSMTPCLI

# Alternative: Run with full debug logging and capture all protocol communication
ENABLE_DEBUG_OUTPUT=1 OS_LOG_DISABLE=0 swift run SwiftIMAPCLI & log stream --predicate 'process == "SwiftIMAPCLI"' --debug
ENABLE_DEBUG_OUTPUT=1 OS_LOG_DISABLE=0 swift run SwiftSMTPCLI & log stream --predicate 'process == "SwiftSMTPCLI"' --debug
```

The debug logging options:
- `ENABLE_DEBUG_OUTPUT=1`: Enables trace level logging
- `OS_ACTIVITY_DT_MODE=debug`: Formats debug output in a readable way
- `OS_LOG_DISABLE=0`: Ensures OS logging is not suppressed
- `log stream`: Captures all system logs for the process, including protocol communication

## Usage

### SwiftIMAP Example

```swift
import SwiftIMAP

// Create an IMAP server connection
let imapServer = IMAPServer(host: "imap.example.com", port: 993)

// Connect to the server
try await imapServer.connect()

// Login with credentials
try await imapServer.login(username: "user@example.com", password: "password")

// Select a mailbox
let mailboxInfo = try await imapServer.selectMailbox("INBOX")
print("Mailbox has \(mailboxInfo.messageCount) messages")

// Fetch the 10 most recent email headers
let startMessage = SequenceNumber(max(1, mailboxInfo.messageCount - 9))
let endMessage = SequenceNumber(mailboxInfo.messageCount)
let headers = try await imapServer.fetchHeaders(using: SequenceNumberSet(startMessage...endMessage))
for header in headers {
    print("Subject: \(header.subject)")
}

// Logout and close the connection
try await imapServer.logout()
try await imapServer.close()
```

### SwiftSMTP Example

```swift
import SwiftSMTP

// Create an SMTP server connection
let smtpServer = SMTPServer(host: "smtp.example.com", port: 587)

// Connect to the server
try await smtpServer.connect()

// Authenticate with the server
try await smtpServer.authenticate(username: "user@example.com", password: "password")

// Create an email
let sender = EmailAddress(address: "sender@example.com", name: "Sender Name")
let recipient = EmailAddress(address: "recipient@example.com", name: "Recipient Name")
let email = Email(
    sender: sender,
    recipients: [recipient],
    subject: "Hello from SwiftSMTP",
    body: "This is a test email sent using SwiftSMTP."
)

// Send the email
try await smtpServer.sendEmail(email)

// Disconnect from the server
try await smtpServer.disconnect()
```

## Testing

The project uses [Swift Testing](https://github.com/apple/swift-testing) for unit tests. To run the tests:

```bash
swift test
```

## Requirements

- Swift 5.9+
- macOS 11.0+
- iOS 14.0+
- tvOS 14.0+
- watchOS 7.0+
- macCatalyst 14.0+

## Dependencies

- [SwiftNIO](https://github.com/apple/swift-nio)
- [SwiftNIOSSL](https://github.com/apple/swift-nio-ssl)
- [SwiftNIOIMAP](https://github.com/apple/swift-nio-imap) (for IMAP only)
- [SwiftDotenv](https://github.com/thebarndog/swift-dotenv) (for CLI demos)
- [Swift Testing](https://github.com/apple/swift-testing) (for tests only)
- [Swift Logging](https://github.com/apple/swift-log)

## License

This project is licensed under the MIT License - see the LICENSE file for details. 
