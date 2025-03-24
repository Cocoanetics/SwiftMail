# ``SwiftMail``

A Swift package for comprehensive email functionality, providing robust IMAP and SMTP client implementations.

## Overview

SwiftMail is a powerful email package that enables you to work with email protocols in your Swift applications. The package provides two main components:

### IMAPServer
Handles IMAP server connections for retrieving and managing emails. Implements key IMAP capabilities including:
- Mailbox operations (SELECT, LIST, COPY, MOVE)
- Message operations (FETCH headers/parts/structure, STORE flags)
- Special-use mailbox support
- TLS encryption
- UID-based operations via UIDPLUS

Learn more: <doc:GettingStartedWithIMAP>
Tutorial: <doc:WorkingWithIMAP>

### SMTPServer
Handles email sending via SMTP with support for:
- Multiple authentication methods (PLAIN, LOGIN)
- TLS encryption
- 8BITMIME support
- Full MIME email composition
- Multiple recipients (To, CC, BCC)

Learn more: <doc:GettingStartedWithSMTP>
Tutorial: <doc:SendingEmailsWithSMTP>

## Topics

### Getting Started

- <doc:Installation>
- <doc:GettingStartedWithIMAP>
- <doc:GettingStartedWithSMTP>

### Tutorials

- <doc:WorkingWithIMAP>
- <doc:SendingEmailsWithSMTP>

### Core Types

- ``IMAPServer``
- ``SMTPServer``
- ``Email``
- ``EmailAddress``

### Email Operations

- ``IMAPServer/connect()``
- ``IMAPServer/login(username:password:)``
- ``IMAPServer/selectMailbox(_:)``
- ``SMTPServer/connect()``
- ``SMTPServer/authenticate(username:password:)``
- ``SMTPServer/sendEmail(_:)``
