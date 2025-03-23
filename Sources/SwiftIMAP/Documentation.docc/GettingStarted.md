# Getting Started with SwiftIMAP

Learn how to use SwiftIMAP to interact with email servers using the IMAP protocol.

## Overview

SwiftIMAP provides a Swift-native implementation of the IMAP protocol, allowing you to access and manage email messages on IMAP servers. This guide will walk you through the basic setup and common operations.

## Basic Setup

First, import SwiftIMAP and configure logging:

```swift
import SwiftIMAP
import Logging

// Configure logging with appropriate level
LoggingSystem.bootstrap { label in
    var logger = Logger(label: label)
    #if DEBUG
    if ProcessInfo.processInfo.environment["ENABLE_DEBUG_OUTPUT"] == "1" {
        logger.logLevel = .trace  // For IMAP protocol-level logging
    } else {
        logger.logLevel = .debug
    }
    #else
    logger.logLevel = .info
    #endif
    return logger
}

let logger = Logger(label: "com.swiftmail.imap")
```

### Creating an IMAP Connection

To connect to an IMAP server, first create an IMAPServer instance:

```swift
let server = IMAPServer(
    host: "imap.gmail.com",
    port: 993,
    numberOfThreads: 1
)
```

### Authentication

You can authenticate using username and password:

```swift
do {
    let loginCommand = LoginCommand(username: "user@example.com", password: "your-password")
    try await server.execute(loginCommand)
    logger.notice("Successfully authenticated to IMAP server")
} catch {
    logger.error("Authentication failed: \(error)")
}
```

### Basic Operations

#### List Mailboxes

```swift
do {
    let mailboxes = try await server.listMailboxes()
    logger.info("Found \(mailboxes.count) mailboxes")
    
    for mailbox in mailboxes {
        logger.debug("Mailbox: \(mailbox.name), Attributes: \(mailbox.attributes)")
    }
} catch {
    logger.error("Failed to list mailboxes: \(error)")
}
```

#### Select a Mailbox

```swift
do {
    let status = try await server.select(mailbox: "INBOX")
    logger.info("Selected INBOX with \(status.messageCount) messages")
} catch {
    logger.error("Failed to select mailbox: \(error)")
}
```

#### Fetch Messages

```swift
do {
    // Create a set of the last 10 messages
    guard let messageSet = status.latest(10) else {
        logger.warning("No messages in mailbox")
        return
    }
    
    logger.debug("Fetching last 10 messages")
    let fetchCommand = FetchMessagePartCommand(
        identifier: messageSet.first,
        sectionPath: []  // Empty path for entire message
    )
    
    let messageData = try await server.execute(fetchCommand)
    logger.info("Successfully fetched message data")
} catch {
    logger.error("Failed to fetch messages: \(error)")
}
```

#### Move Messages

```swift
do {
    let messageSet = MessageIdentifierSet<UID>([UID(1), UID(2), UID(3)])
    let moveCommand = MoveCommand(
        identifierSet: messageSet,
        destinationMailbox: "Archive"
    )
    
    try await server.execute(moveCommand)
    logger.notice("Successfully moved messages to Archive")
} catch {
    logger.error("Failed to move messages: \(error)")
}
```

## Best Practices

### Logging
- Use trace-level logging for IMAP protocol commands and responses
- Enable debug output during development with `ENABLE_DEBUG_OUTPUT=1`
- Always redact sensitive information in logs
- Use appropriate log levels for different operations:
  - `.trace`: Protocol commands and responses
  - `.debug`: Detailed operation information
  - `.info`: General operation success
  - `.notice`: Important state changes
  - `.warning`: Potential issues
  - `.error`: Operation failures

### Connection Management
- Always close connections when done
- Handle connection errors gracefully
- Implement appropriate timeouts
- Use TLS when possible for security

## Next Steps

- Learn about message operations with ``Message``
- Explore mailbox management with ``Mailbox``
- Understand message identifiers with ``MessageIdentifier``

## Topics

### Essentials

- ``IMAPServer``
- ``Message``
- ``Mailbox``

### Message Operations

- ``MessageIdentifier``
- ``MessageIdentifierSet``
- ``FetchMessagePartCommand`` 