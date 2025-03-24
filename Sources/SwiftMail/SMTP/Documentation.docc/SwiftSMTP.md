# ``SwiftSMTP``

A Swift implementation of the SMTP (Simple Mail Transfer Protocol).

## Overview

SwiftSMTP provides a modern, Swift-native implementation of the SMTP protocol, allowing you to send emails through SMTP servers. Built on top of SwiftNIO, it offers both synchronous and asynchronous APIs for email operations.

## Topics

### Essentials

- <doc:GettingStarted>
- ``SMTPServer``
- ``SMTPCommand``
- ``SMTPCommandHandler``

### Message Operations

- ``SendContentCommand``
- ``MailFromCommand``
- ``RcptToCommand``
- ``DataCommand``

### Authentication

- ``AuthCommand``
- ``PlainAuthCommand``
- ``AuthResult``
- ``AuthHandlerStateMachine``

### Connection Management

- ``StartTLSCommand``
- ``QuitCommand``
- ``SMTPResponse``
- ``SMTPError``

## Installation

You can add SwiftSMTP as a dependency to your project using Swift Package Manager.

Add the following to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/Cocoanetics/SwiftMail.git", from: "1.0.0")
]
```

Then add SwiftSMTP as a dependency to your target:

```swift
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "SwiftSMTP", package: "SwiftMail")
        ]
    )
]
``` 