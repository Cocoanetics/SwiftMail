# Using IMAP IDLE

Learn how to monitor mailbox changes in real time with SwiftMail.

## Overview

The ``IMAPServer`` actor supports the IMAP `IDLE` extension. This allows your application to receive updates as soon as they happen without polling.

## Starting IDLE

```swift
let events = try await imapServer.idle()
```

The returned asynchronous sequence yields ``IMAPServerEvent`` values whenever the server reports new messages, expunges or flag changes.

## Handling Events

```swift
for await event in events {
    switch event {
    case .newMessage(let uid):
        print("New message UID: \(uid.value)")
    case .expunge(let sequence):
        print("Message removed: \(sequence.value)")
    case .flagsChanged(let sequence, let flags):
        print("Flags for \(sequence.value) now \(flags)")
    case .bye:
        print("Server closed the connection")
    }
}
```

## Exiting IDLE

When finished processing updates, call:

```swift
try await imapServer.done()
```

This sends the `DONE` command and returns to normal operation.

## Topics

- ``IMAPServer``
- ``IMAPServerEvent``
