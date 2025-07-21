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

By default `listMailboxes()` uses the `"*"` wildcard, but you can specify a
different pattern if needed:

```swift
// Only list top-level mailboxes
let mailboxes = try await imapServer.listMailboxes(wildcard: "%")
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

## Searching Messages

SwiftMail provides powerful search capabilities using different types of message identifiers:

```swift
// Define message identifier set types for searching
let unreadMessagesSet: MessageIdentifierSet<SequenceNumber> // Uses temporary sequence numbers
let sampleMessagesSet: MessageIdentifierSet<UID> // Uses permanent unique identifiers

// Search for unread messages using sequence numbers
print("\nSearching for unread messages...")
unreadMessagesSet = try await imapServer.search(criteria: [.unseen])
print("Found \(unreadMessagesSet.count) unread messages")

// Search for messages with a specific subject using UIDs
print("\nSearching for sample emails...")
sampleMessagesSet = try await imapServer.search(criteria: [.subject("SwiftSMTPCLI")])
print("Found \(sampleMessagesSet.count) sample emails")
```

The search functionality supports two types of message identifiers:
- **SequenceNumber**: Temporary numbers assigned to messages in a mailbox that change frequently
- **UID**: Message identifiers that are more stable than sequence numbers but can still change between sessions or when the mailbox is modified

Common search criteria include:
- `.unseen`: Find unread messages
- `.subject(String)`: Search by subject text
- `.from(String)`: Search by sender
- `.to(String)`: Search by recipient
- `.before(Date)`: Find messages before a date
- `.since(Date)`: Find messages since a date

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

## Cleanup

Always remember to properly close your connection:

```swift
// Logout from the server
try await imapServer.logout()

// Close the connection
try await imapServer.close()
```

## Special Mailboxes

SwiftMail provides easy access to common special-use mailboxes:

```swift
// Get standard mailboxes
let inbox = try imapServer.inboxFolder
let sent = try imapServer.sentFolder
let trash = try imapServer.trashFolder
let drafts = try imapServer.draftsFolder
let junk = try imapServer.junkFolder
let archive = try imapServer.archiveFolder
```

## Message Operations

### Copying Messages

Copy messages between mailboxes:

```swift
// Copy messages using sequence numbers or UIDs
let messageSet: MessageIdentifierSet<UID> = // ... your message set ...
try await imapServer.copy(messageSet, to: "Archive")
```

### Managing Message Flags

Set or remove flags on messages:

```swift
// Mark messages as read
let unreadSet: MessageIdentifierSet<UID> = // ... your message set ...
try await imapServer.store(unreadSet, flags: [.seen], operation: .add)

// Mark messages as deleted
let messageSet: MessageIdentifierSet<UID> = // ... your message set ...
try await imapServer.store(messageSet, flags: [.deleted], operation: .add)
```

### Expunging Deleted Messages

Remove messages marked for deletion:

```swift
// Permanently remove messages marked as deleted
try await imapServer.expunge()
```

## Mailbox Management

### Closing a Mailbox

Close the currently selected mailbox:

```swift
// Close mailbox and expunge deleted messages
try await imapServer.closeMailbox()

// Close mailbox without expunging (if supported by server)
try await imapServer.unselectMailbox()
```

## Next Steps

- Learn more about IMAP operations in <doc:WorkingWithIMAP>
- Explore the ``IMAPServer`` API documentation
- Check out the demo apps in the repository

## Topics

- ``IMAPServer``
