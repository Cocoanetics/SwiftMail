# Getting Started with SwiftMailCore

Learn how to integrate and use SwiftMailCore in your Swift projects.

## Overview

SwiftMailCore provides the foundation for email-related operations in the SwiftMail framework. This guide will help you get started with the basic concepts and show you how to integrate SwiftMailCore into your project.

## Basic Setup

First, import SwiftMailCore in your Swift file:

```swift
import SwiftMailCore
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

### Creating a Connection Configuration

To establish connections for email operations, you'll need to create a connection configuration:

```swift
let config = ConnectionConfiguration(
    host: "mail.example.com",
    port: 993,
    useTLS: true
)
```

### Error Handling

SwiftMailCore provides a unified error type for handling email-related errors:

```swift
do {
    // Your email operation here
} catch let error as MailError {
    switch error {
    case .connectionFailed(let reason):
        logger.error("Connection failed: \(reason)")
    case .authenticationFailed:
        logger.error("Authentication failed")
    default:
        logger.error("An error occurred: \(error)")
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

### Connection Management
- Always close connections when done
- Handle connection errors gracefully
- Implement appropriate timeouts
- Use TLS when possible for security

## Next Steps

- Learn about the IMAP implementation in ``SwiftIMAP``
- Explore SMTP functionality in ``SwiftSMTP``
- Check out the available networking options in ``Connection``

## Topics

### Essentials

- ``Connection``
- ``ConnectionConfiguration``
- ``MailError``

### Advanced Topics

- ``LoggingSystem``
- ``MailAddress``
- ``MailHeaders`` 