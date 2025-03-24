# SwiftMail

A Swift package for comprehensive email functionality, providing robust IMAP and SMTP client implementations.

## Overview

SwiftMail is a powerful email package that enables you to work with email protocols in your Swift applications. The package provides two main components:

### IMAPServer
Handles IMAP server connections for retrieving and managing emails. Implements key IMAP capabilities including:
- Mailbox operations (SELECT, LIST, COPY, MOVE)
- Message operations (FETCH headers/parts/structure, STORE flags)
- Special-use mailbox support
- TLS encryption
- UID-based operations via UIDPLUS

### SMTPServer
Handles email sending via SMTP with support for:
- Multiple authentication methods (PLAIN, LOGIN)
- TLS encryption
- 8BITMIME support
- Full MIME email composition
- Multiple recipients (To, CC, BCC)

## Command Line Demos

The package includes command line demos that showcase the functionality of both the IMAP and SMTP libraries:

- **SwiftIMAPCLI**: Demonstrates IMAP operations like listing mailboxes and fetching messages
- **SwiftSMTPCLI**: Demonstrates sending emails via SMTP

Both demos look for a `.env` file in the current working directory for configuration. Create a `.env` file with the following variables:

```
# IMAP Configuration
IMAP_HOST=imap.example.com
IMAP_PORT=993
IMAP_USERNAME=your_username
IMAP_PASSWORD=your_password

# SMTP Configuration
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USERNAME=your_username
SMTP_PASSWORD=your_password
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
```

The debug logging options:
- `ENABLE_DEBUG_OUTPUT=1`: Enables trace level logging
- `OS_ACTIVITY_DT_MODE=debug`: Formats debug output in a readable way

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

This project is licensed under the BSD 2-Clause License - see the LICENSE file for details. 
