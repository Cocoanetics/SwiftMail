# Getting Started with IMAP

Learn how to use SwiftMail's IMAP functionality to connect to email servers and manage messages.

## Overview

The `IMAPServer` class provides a Swift-native interface for working with IMAP servers. This guide will walk you through the basic steps of connecting to an IMAP server and performing common operations.

## Creating an IMAP Server Instance

First, create an instance of `IMAPServer` with your server details:

```swift
import SwiftMail

let imapServer = IMAPServer(host: "imap.example.com", port: 993)
```

The default port for IMAP over SSL/TLS is 993. For non-SSL connections, use port 143.

## Connecting and Authentication

Connect to the server and authenticate with your credentials:

```swift
try await imapServer.connect()
try await imapServer.login(username: "user@example.com", password: "password")
```

## Working with Mailboxes

List available mailboxes and select one to work with:

```swift
// List mailboxes
let mailboxes = try await imapServer.listMailboxes()
for mailbox in mailboxes {
    print("📬 \(mailbox.name)")
}

// Select a mailbox
let mailboxInfo = try await imapServer.selectMailbox("INBOX")
print("Mailbox contains \(mailboxInfo.messageCount) messages")
```

## Fetching Messages

Fetch messages from the selected mailbox:

```swift
// Get the latest 10 messages
if let latestMessagesSet = mailboxInfo.latest(10) {
    let emails = try await imapServer.fetchMessages(using: latestMessagesSet)
    print("Fetched \(emails.count) messages")
}
```

## Error Handling

SwiftMail uses Swift's error handling system. Common errors include:
- Network connectivity issues
- Authentication failures
- Invalid mailbox names
- Server timeouts

Always wrap IMAP operations in try-catch blocks:

```swift
do {
    try await imapServer.connect()
    try await imapServer.login(username: "user@example.com", password: "password")
} catch {
    print("IMAP error: \(error)")
}
```

## Next Steps

- Learn more about IMAP operations in <doc:WorkingWithIMAP>
- Explore the ``IMAPServer`` API documentation
- Check out the demo apps in the repository

## Topics

### Essentials

- ``IMAPServer``

### Common Operations

- ``IMAPServer/connect()``
- ``IMAPServer/login(username:password:)``
- ``IMAPServer/listMailboxes()``
- ``IMAPServer/selectMailbox(_:)``
- ``IMAPServer/fetchMessages(using:)`` 