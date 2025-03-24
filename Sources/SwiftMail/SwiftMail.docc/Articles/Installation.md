# Installing SwiftMail

Learn how to add SwiftMail to your Swift project and configure it for use.

## Overview

SwiftMail can be integrated into your project using Swift Package Manager. This guide will walk you through the installation process and initial setup.

## Adding SwiftMail as a Dependency

### Using Swift Package Manager

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

### Using Xcode

If you're using Xcode, you can add SwiftMail directly through the Xcode UI:

1. In Xcode, select File > Add Packages...
2. Enter the repository URL: `https://github.com/Cocoanetics/SwiftMail.git`
3. Select "Branch" as the dependency rule and choose "main"
4. Select the target you want to add SwiftMail to
5. Click Add Package

## Configuration

### Environment Variables

For development and testing, you can use environment variables to configure your email servers. Create a `.env` file in your project root:

```
# IMAP Configuration
IMAP_HOST=imap.example.com
IMAP_PORT=993
IMAP_USERNAME=your_username
IMAP_PASSWORD=your_password

# SMTP Configuration
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USERNAME=your_username
SMTP_PASSWORD=your_password
```

### Security Considerations

- Never commit email credentials to version control
- Use environment variables or a secure configuration management system
- Consider using app-specific passwords for increased security
- Enable SSL/TLS for secure connections

## Next Steps

- Learn about IMAP operations in <doc:WorkingWithIMAP>
- Explore SMTP functionality in <doc:SendingEmailsWithSMTP>

## Topics

### Tutorials

- <doc:WorkingWithIMAP>
- <doc:SendingEmailsWithSMTP> 