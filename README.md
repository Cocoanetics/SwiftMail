# SwiftIMAP

A Swift library for interacting with IMAP servers.

## Features

- Connect to IMAP servers securely using SSL/TLS
- Authenticate with username and password
- Select mailboxes and retrieve mailbox information
- Fetch email headers and message parts
- Handle MIME-encoded content and quoted-printable encoding
- Save message parts to disk for debugging

## Project Structure

The project is organized as follows:

- **Sources/SwiftIMAP/Core**: Contains the main IMAP functionality
  - **IMAPServer.swift**: The main class for IMAP server connections
  - **IMAPResponseHandler.swift**: Handles IMAP server responses

- **Sources/SwiftIMAP/Models**: Contains data models used throughout the library
  - **EmailHeader.swift**: Represents an email header
  - **MailboxInfo.swift**: Contains information about a mailbox
  - **MessagePart.swift**: Represents a part of an email message
  - **IMAPError.swift**: Custom error types for IMAP operations

- **Sources/SwiftIMAP/Extensions**: Contains Swift extensions for various types
  - **String+QuotedPrintable.swift**: Extensions for handling quoted-printable encoding
  - **String+Utilities.swift**: Utility extensions for strings
  - **Data+Utilities.swift**: Utility extensions for data
  - **Int+Utilities.swift**: Utility extensions for integers
  - **ByteBuffer+StringValue.swift**: Extension for ByteBuffer
  - **MessageID+StringValue.swift**: Extension for MessageID
  - **NIOSSLClientHandler+Sendable.swift**: Extension for NIOSSLClientHandler

- **Sources/SwiftIMAPCLI**: Contains the command-line interface application

## Coding Standards

This project follows a set of coding standards defined in the `.cursor.rules` file. Key principles include:

- Protocol conformances should be in separate files named `Type+Protocol.swift`
- Convenience methods should be formulated as extensions on Foundation base types
- Public interfaces should be clearly defined with appropriate access control
- Imports should be kept to the absolute minimum required
- String conversions should prefer custom initializers (`String(value)`)
- Single-line functions should be replaced with direct implementation

For the complete set of coding standards, please refer to the `.cursor.rules` file in the project root.

## Usage

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
let headers = try await imapServer.fetchHeaders(range: "1:10")
for header in headers {
    print("Subject: \(header.subject)")
    print("From: \(header.from)")
    print("Date: \(header.date)")
}

// Fetch all parts of a message
let parts = try await imapServer.fetchAllMessageParts(sequenceNumber: 1)
for part in parts {
    print("Part #\(part.partNumber): \(part.contentType)/\(part.contentSubtype)")
    if let textContent = part.textContent() {
        print("Content: \(textContent.prefix(100))...")
    }
}

// Logout and close the connection
try await imapServer.logout()
try await imapServer.close()
```

## Requirements

- Swift 5.7+
- macOS 11.0+

## Dependencies

- [SwiftNIO](https://github.com/apple/swift-nio)
- [SwiftNIOSSL](https://github.com/apple/swift-nio-ssl)
- [SwiftNIOIMAP](https://github.com/apple/swift-nio-imap)
- [SwiftDotenv](https://github.com/thebarndog/swift-dotenv) (for CLI only)

## License

This project is licensed under the MIT License - see the LICENSE file for details. 