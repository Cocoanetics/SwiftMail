# Getting Started with SwiftMailCore

Learn how to integrate and use SwiftMailCore in your Swift projects.

## Overview

SwiftMailCore provides the foundation for email-related operations in the SwiftMail framework. This guide will help you get started with the basic concepts and show you how to integrate SwiftMailCore into your project.

## Basic Setup

First, import SwiftMail in your Swift file:

```swift
import SwiftMail
```

### Configuring Logging

SwiftMailCore uses Apple's swift-log package for logging. Here's how to set up basic logging:

```swift
import Logging

// Configure the logging system
LoggingSystem.bootstrap { label in
    var logger = Logger(label: label)
    // Set appropriate log level based on environment
    #if DEBUG
    logger.logLevel = .debug  // More detailed logging during development
    #else
    logger.logLevel = .info   // Standard logging in production
    #endif
    return logger
}
```

Log levels are used as follows:
- `.critical`: Fatal application errors
- `.error`: Errors that impact functionality but allow recovery
- `.warning`: Potential issues that don't impact functionality
- `.notice`: Important events in normal operation
- `.info`: General information about application flow
- `.debug`: Detailed debugging information
- `.trace`: Protocol-level tracing (commands and responses)

### Creating Email Messages

To create an email message:

```swift
let sender = EmailAddress(name: "John Doe", address: "john@example.com")
let recipient = EmailAddress(name: "Jane Smith", address: "jane@example.com")

let email = Email(
    sender: sender,
    recipients: [recipient],
    subject: "Hello from SwiftMail",
    textBody: "This is a test email!",
    htmlBody: "<html><body><h1>Hello!</h1><p>This is a test email!</p></body></html>"
)
```

### Adding Attachments

You can add attachments to your email:

```swift
let attachment = Attachment(
    filename: "document.pdf",
    mimeType: "application/pdf",
    data: fileData,
    isInline: false
)

var emailWithAttachment = email
emailWithAttachment.attachments = [attachment]
```

### Error Handling

SwiftMailCore provides a unified error type for handling email-related errors:

```swift
do {
    // Your email operation here
} catch let error as MailError {
    switch error {
    case .connectionError(let reason):
        logger.error("Connection error: \(reason)")
    case .authenticationFailed(let reason):
        logger.error("Authentication failed: \(reason)")
    case .timeout(let reason):
        logger.error("Operation timed out: \(reason)")
    case .general(let reason):
        logger.error("An error occurred: \(reason)")
    }
}
```

## Best Practices

### Logging
- Use appropriate log levels for different types of information
- Ensure log messages are clear and concise
- Avoid technical jargon in log messages
- Always redact sensitive information (passwords, tokens)
- Use `ENABLE_DEBUG_OUTPUT=1` during development
- Avoid direct `print()` calls in favor of the logging system

### Email Composition
- Always validate email addresses
- Use proper line endings (CRLF)
- Follow RFC 5322 format for headers
- Handle different character encodings properly

## Next Steps

- Explore IMAP functionality in SwiftMail's IMAP module
- Explore SMTP functionality in SwiftMail's SMTP module
- Check out the command handling with ``MailCommand``

## Topics

### Essentials

- ``Email``
- ``EmailAddress``
- ``MailError``

### Command Handling

- ``MailCommand``
- ``MailCommandHandler``
- ``BaseMailCommandHandler``

### Attachments

- ``Attachment`` 