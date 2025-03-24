# ``SwiftIMAP``

A Swift implementation of the IMAP (Internet Message Access Protocol).

## Overview

SwiftIMAP provides a modern, Swift-native implementation of the IMAP protocol, allowing you to interact with email servers to access and manage email messages. Built on top of SwiftNIO and SwiftNIOIMAP, it offers both synchronous and asynchronous APIs for email operations.

## Topics

### Essentials

- <doc:GettingStarted>
- ``IMAPServer``
- ``Message``
- ``Header``

### Message Operations

- ``MessageIdentifier``
- ``UID``
- ``SequenceNumber``
- ``MessageIdentifierSet``

### Mailbox Management

- ``Mailbox``
- ``IMAPCommand``
- ``IMAPCommandHandler``

### Commands

- ``FetchMessagePartCommand``
- ``FetchStructureCommand``
- ``CopyCommand``
- ``MoveCommand``
- ``StoreCommand``
- ``ExpungeCommand``
- ``CloseCommand``
- ``UnselectCommand``
- ``LoginCommand``
- ``LogoutCommand``

## Installation

You can add SwiftIMAP as a dependency to your project using Swift Package Manager.

Add the following to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/Cocoanetics/SwiftMail.git", from: "1.0.0")
]
```

Then add SwiftIMAP as a dependency to your target:

```swift
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "SwiftIMAP", package: "SwiftMail")
        ]
    )
]
``` 