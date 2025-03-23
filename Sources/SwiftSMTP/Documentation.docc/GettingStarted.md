# Getting Started with SwiftSMTP

Learn how to use SwiftSMTP to send emails using the SMTP protocol.

## Overview

SwiftSMTP provides a Swift-native implementation of the SMTP protocol, allowing you to send emails through SMTP servers. This guide will walk you through the basic setup and common operations.

## Basic Setup

First, import SwiftSMTP and configure logging:

```swift
import SwiftSMTP
import Logging

// Configure logging with appropriate level
LoggingSystem.bootstrap { label in
    var logger = Logger(label: label)
    #if DEBUG
    if ProcessInfo.processInfo.environment["ENABLE_DEBUG_OUTPUT"] == "1" {
        logger.logLevel = .trace  // For SMTP protocol-level logging
    } else {
        logger.logLevel = .debug
    }
    #else
    logger.logLevel = .info
    #endif
    return logger
}

let logger = Logger(label: "com.swiftmail.smtp")
```

### Creating an SMTP Connection

To connect to an SMTP server, first create an SMTPServer instance:

```swift
let server = SMTPServer(
    host: "smtp.gmail.com",
    port: 587,
    numberOfThreads: 1
)
```

### Authentication

You can authenticate using username and password:

```swift
do {
    let authCommand = AuthCommand(
        username: "user@example.com",
        password: "your-password",
        method: .plain
    )
    let result = try await server.execute(authCommand)
    
    if result.success {
        logger.notice("Successfully authenticated to SMTP server")
    } else if let error = result.errorMessage {
        logger.error("Authentication failed: \(error)")
    }
} catch {
    logger.error("Authentication failed: \(error)")
}
```

### Sending Emails

#### Basic Email

```swift
do {
    // Start with MAIL FROM command
    let mailFromCmd = try MailFromCommand(senderAddress: "sender@example.com")
    _ = try await server.execute(mailFromCmd)
    
    // Add recipient with RCPT TO command
    let rcptToCmd = try RcptToCommand(recipientAddress: "recipient@example.com")
    _ = try await server.execute(rcptToCmd)
    
    // Start data transmission
    let dataCmd = DataCommand()
    _ = try await server.execute(dataCmd)
    
    // Send the email content
    let content = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Hello from SwiftSMTP
        
        This is a test email sent using SwiftSMTP!
        """
    
    let sendContentCmd = SendContentCommand(email: content)
    try await server.execute(sendContentCmd)
    
    logger.notice("Email sent successfully")
} catch {
    logger.error("Failed to send email: \(error)")
}
```

#### Clean Disconnection

Always close the connection when done:

```swift
do {
    let quitCmd = QuitCommand()
    _ = try await server.execute(quitCmd)
    logger.info("SMTP connection closed cleanly")
} catch {
    logger.error("Error closing connection: \(error)")
}
```

## Best Practices

### Logging
- Use trace-level logging for SMTP protocol commands and responses
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
- Always close connections when done using `QuitCommand`
- Handle connection errors gracefully
- Implement appropriate timeouts
- Use TLS when possible for security with `StartTLSCommand`

### Email Composition
- Always validate email addresses
- Use proper line endings (CRLF)
- Follow RFC 5322 format for headers
- Handle different character encodings properly

## Next Steps

- Learn about authentication options with ``AuthCommand``
- Explore email sending with ``SendContentCommand``
- Understand error handling with ``SMTPError``

## Topics

### Essentials

- ``SMTPServer``
- ``SMTPCommand``
- ``SMTPResponse``

### Email Operations

- ``MailFromCommand``
- ``RcptToCommand``
- ``DataCommand``
- ``SendContentCommand`` 