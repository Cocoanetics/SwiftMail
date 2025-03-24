# Getting Started with SwiftMail

Learn how to integrate SwiftMail into your Swift project and start working with email functionality.

## Overview

SwiftMail provides a powerful set of tools for working with email in your Swift applications. This guide will help you get started with the basic setup and show you how to perform common email operations.

## Adding SwiftMail to Your Project

Add SwiftMail to your project using Swift Package Manager by adding it as a dependency in your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/Cocoanetics/SwiftMail.git", branch: "main")
]
```

Then add SwiftMail to your target's dependencies:

```swift
targets: [
    .target(
        name: "YourTarget",
        dependencies: ["SwiftMail"]
    )
]
```

## Basic Usage

### Working with Email Addresses

```swift
import SwiftMail

// Create email addresses
let sender = EmailAddress(address: "sender@example.com", name: "John Doe")
let recipient = EmailAddress(address: "recipient@example.com", name: "Jane Smith")
```

### Creating and Sending Emails

```swift
// Create an email
let email = Email(
    sender: sender,
    recipients: [recipient],
    subject: "Hello from SwiftMail",
    body: "This is a test email sent using SwiftMail."
)

// Configure SMTP server
let smtpServer = SMTPServer(host: "smtp.example.com", port: 587)
try await smtpServer.connect()
try await smtpServer.authenticate(username: "user@example.com", password: "password")

// Send the email
try await smtpServer.sendEmail(email)
```

### Receiving Emails

```swift
// Configure IMAP server
let imapServer = IMAPServer(host: "imap.example.com", port: 993)
try await imapServer.connect()
try await imapServer.login(username: "user@example.com", password: "password")

// Select inbox
let mailboxInfo = try await imapServer.selectMailbox("INBOX")

// Fetch latest messages
if let latestMessages = mailboxInfo.latest(10) {
    let emails = try await imapServer.fetchMessages(using: latestMessages)
    for email in emails {
        print("Subject: \(email.subject)")
    }
}
```

## Next Steps

- Learn more about IMAP operations in <doc:WorkingWithIMAP>
- Explore SMTP functionality in <doc:SendingEmailsWithSMTP>
- Check out the installation options in <doc:Installation>

## Topics

### Essentials

- <doc:Installation>
- <doc:WorkingWithIMAP>
- <doc:SendingEmailsWithSMTP> 