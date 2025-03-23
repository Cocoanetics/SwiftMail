# ``SwiftMailCore``

Core functionality shared between IMAP and SMTP implementations in SwiftMail.

## Overview

SwiftMailCore provides the foundational components and utilities used by both the IMAP and SMTP implementations in the SwiftMail framework. Built on top of SwiftNIO, it offers robust networking capabilities and standardized logging through swift-log.

## Topics

### Essentials

- <doc:GettingStarted>
- ``MailCommand``
- ``MailCommandHandler``
- ``MailError``

### Email Types

- ``Email``
- ``EmailAddress``
- ``Attachment``

### Logging

- ``MailLogger``
- ``MailResponse``

### Base Types

- ``BaseMailCommandHandler``

## Installation

You can add SwiftMailCore as a dependency to your project using Swift Package Manager.

Add the following to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/Cocoanetics/SwiftMail.git", from: "1.0.0")
]
```

Then add SwiftMailCore as a dependency to your target:

```swift
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "SwiftMailCore", package: "SwiftMail")
        ]
    )
]
``` 