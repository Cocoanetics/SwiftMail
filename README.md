# SwiftMail

A Swift package for comprehensive email functionality, providing robust IMAP and SMTP client implementations.

## Overview

SwiftMail is a powerful email package that enables you to work with email protocols in your Swift applications. The package provides two main components:

### IMAPServer
Handles IMAP server connections for retrieving and managing emails. Implements key IMAP capabilities including:
- Mailbox operations (SELECT, LIST, COPY, MOVE)
- Message operations (FETCH headers/parts/structure, STORE flags)
- Special-use mailbox support
- Creating new messages via APPEND (draft-friendly)
- TLS encryption
- UID-based operations via UIDPLUS

### 📊 IMAP Capability Support: Gmail vs iCloud vs Dovecot vs Exchange vs IMAPServer

The table below compares common IMAP capabilities across Gmail, iCloud, Dovecot, Exchange,
and SwiftMail's `IMAPServer`. `NIOIMAP` indicates capability/command/parser support present in the underlying `swift-nio-imap` grammar layer. The final column indicates whether `IMAPServer`
implements support for each capability.

| IMAP Capability | Description | Gmail | iCloud | Dovecot | Exchange | NIOIMAP | IMAPServer |
|-----------------|---------------------------------------------------------------|:-----:|:------:|:-------:|:--------:|:------:|:----------:|
| **IMAP4rev1** | Standard IMAP protocol (RFC 3501) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **UNSELECT** | Unselect mailbox without selecting another (RFC 3691) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **IDLE** | Push new message alerts (RFC 2177) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **NAMESPACE** | Query folder structure roots (RFC 2342) | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| **QUOTA** | Storage quota reporting (RFC 2087) | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ |
| **ID** | Identify client/server (RFC 2971) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **XLIST** | Gmail folder role mapping (legacy) | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **CHILDREN** | Show folder substructure (RFC 3348) | ✅ | ❌ | ✅ | ✅ | ✅ | ❌ |
| **X-GM-EXT-1** | Gmail labels, threads, msg IDs | ✅ | ❌ | ❌ | ❌ | ✅ | ❌ |
| **UIDPLUS** | Enhanced UID operations (RFC 4315) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **COMPRESS=DEFLATE** | zlib compression (RFC 4978) | ✅ | ❌ | ❌ | ❌ | ✅ | ❌ |
| **ENABLE** | Enable optional extensions (RFC 5161) | ✅ | ✅ | ✅ | ❌ | ✅ | ❌ |
| **MOVE** | Native IMAP MOVE command (RFC 6851) | ✅ | ❌ | ✅ | ✅ | ✅ | ✅ |
| **CONDSTORE** | Efficient state sync (RFC 7162) | ✅ | ✅ | ✅ | ❌ | ✅ | ❌ |
| **ESEARCH** | Extended search (RFC 4731) | ✅ | ✅ | ✅ | ❌ | ✅ | ❌ |
| **UTF8=ACCEPT** | UTF-8 folder & header support (RFC 6855) | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **LIST-EXTENDED** | Advanced mailbox listing (RFC 5258) | ✅ | ❌ | ✅ | ❌ | ✅ | ❌ |
| **LIST-STATUS** | List + status in one (RFC 5819) | ✅ | ✅ | ✅ | ❌ | ✅ | ❌ |
| **LITERAL-** | Literal string optimization (RFC 7888) | ✅ | ❌ | ❌ | ❌ | ✅ | ❌ |
| **SPECIAL-USE** | Modern folder role marking (RFC 6154) | ✅ | ❌ | ✅ | ❌ | ✅ | ✅ |
| **APPENDLIMIT=…** | Message size limit for uploads | ✅ | ❌ | ❌ | ❌ | ✅ | ❌ |
| **QRESYNC** | Quick resync (RFC 5162) | ❌ | ✅ | ✅ | ❌ | ✅ | ❌ |
| **SORT** | Server-side message sorting (RFC 5256) | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ |
| **ESORT** | Extended SORT results (RFC 5267) | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ |
| **CONTEXT=SORT** | Persistent sort context | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |
| **WITHIN** | Search by relative time (RFC 5032) | ❌ | ✅ | ✅ | ❌ | ✅ | ❌ |
| **SASL-IR** | Initial SASL response support (RFC 4959) | ❌ | ✅ | ✅ | ✅ | ✅ | ❌ |
| **XAPPLEPUSHSERVICE** | Apple push integration for Mail app | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |
| **XAPPLELITERAL** | Apple literal transmission optimization | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |
| **X-APPLE-REMOTE-LINKS** | Apple-specific remote links extension | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ |

Exchange source (captured 2026-03-05 from `outlook.office365.com:993` via IMAPS CAPABILITY):

`* CAPABILITY IMAP4 IMAP4rev1 AUTH=PLAIN AUTH=XOAUTH2 SASL-IR UIDPLUS MOVE ID UNSELECT CHILDREN IDLE NAMESPACE LITERAL+`

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

**Note for Gmail Users**: When using Gmail, you cannot authenticate with your Google account password. Instead, you must create an [app-specific password](https://myaccount.google.com/apppasswords) and use that as your password in the configuration above.

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

## Creating Drafts via IMAP

SwiftMail lets you build a draft with the shared `Email` model (also used by SMTP) and store it directly on the server:

```swift
let draft = Email(
    sender: EmailAddress(name: "Me", address: "me@example.com"),
    recipients: [],
    subject: "Quarterly update",
    textBody: "Jot down your notes here…"
)

let appendResult = try await imapServer.createDraft(from: draft)
if let uid = appendResult.firstUID {
    print("Draft stored with UID \(uid.value)")
}
```

Need a custom target mailbox or additional flags? Use the lower-level helper:

```swift
try await imapServer.append(
    email: draft,
    to: "Archive/Drafts",
    flags: [.seen]
)
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

This project is licensed under the BSD 2-Clause License - see the LICENSE file for details. 
