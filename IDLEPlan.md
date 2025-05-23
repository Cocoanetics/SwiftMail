# IMAP IDLE Implementation Plan

This document outlines the steps required to implement the IMAP **IDLE** command in SwiftMail while providing a modern, Swift‑concurrency–friendly API.

## Goals

- Provide a clean Swift interface for starting and stopping IDLE sessions.
- Deliver notifications about mailbox changes using Swift async/await.
- Ensure compatibility with existing command handling infrastructure.

## Proposed Interface

```swift
public actor IMAPServer {
    /// Begin an IDLE session and receive server notifications.
    /// - Returns: An `AsyncStream` of unsolicited responses such as new message arrival.
    public func idle() throws -> AsyncStream<IMAPServerEvent>

    /// Terminate the current IDLE session.
    public func done() async throws
}
```

`IMAPServerEvent` would be an enum representing common events like new messages, expunges or flag changes.

## Implementation Steps

1. **Capability Check**
   - Extend capability parsing so that `IMAPServer` records whether the server advertises `IDLE`.
   - Throw `IMAPError.commandNotSupported` from `idle()` if the capability is missing.

2. **IdleCommand and Handler**
   - Create `IdleCommand` and `IdleHandler` mirroring other command structures.
   - The handler listens for untagged responses until a `DONE` command is sent.

3. **AsyncStream Events**
   - `idle()` returns an `AsyncStream` that yields `IMAPServerEvent` values as the handler receives server notifications.
   - `done()` completes the stream and removes the handler from the pipeline.

4. **Cancellation Support**
   - Respect task cancellation: calling `cancel()` on the task running `idle()` should automatically send `DONE` and clean up.

5. **Documentation and Samples**
   - Add a new article demonstrating how to use IDLE with Swift concurrency.
   - Update `Implemented.md` once the command is fully working.

## Example Usage

```swift
let events = try imapServer.idle()
for await event in events {
    switch event {
    case .newMessage(let uid):
        print("New message with UID \(uid)")
    case .expunge(let sequence):
        print("Message expunged: \(sequence)")
    }
}
```

This plan focuses on exposing IDLE through an asynchronous stream so that client code can react to server events in real time while retaining SwiftMail’s actor-based design.
