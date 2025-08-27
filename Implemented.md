# Implemented Commands and Capabilities

## IMAP

### Capabilities

- [x] SPECIAL-USE - Used to list mailboxes with special-use attributes.
- [x] UIDPLUS - Checked when determining if the server supports the MOVE command with UIDs.
- [x] MOVE - Used to check if the server supports the MOVE command directly.
- [x] IDLE - Allows the server to notify the client of new messages or changes in real-time without the need for the client to poll the server.
- [ ] LITERAL+ - Allows the use of literals in commands without requiring the client to wait for the server's continuation response.
- [ ] COMPRESS=DEFLATE - Enables compression of data sent between the client and server to reduce bandwidth usage.
- [x] QUOTA - Provides support for managing and querying storage quotas on the server.
- [ ] NAMESPACE - Allows the client to discover the namespaces available on the server, which can be useful for clients that need to manage multiple mailboxes.
- [ ] ACL - Provides support for Access Control Lists, allowing clients to manage permissions on mailboxes.
- [ ] SORT - Allows the client to request that the server sort messages based on various criteria, such as date, subject, or sender.
- [ ] THREAD - Allows the client to request that the server return messages in a threaded format, which can be useful for displaying conversations.
- [ ] X-GM-EXT-1 - A Google-specific extension that provides additional capabilities for interacting with Gmail, such as accessing labels and message IDs.

### Commands

#### Capability Commands

- [x] CAPABILITY - Fetch server capabilities.

#### Connection and Login Commands

- [x] LOGIN - Login to the IMAP server.
- [x] LOGOUT - Logout from the IMAP server.

#### Mailbox Commands

- [x] SELECT - Select a mailbox.
- [x] CLOSE - Close the currently selected mailbox.
- [x] LIST - List mailboxes.
  - [x] LIST (SPECIAL-USE) - List mailboxes with special-use attributes.
- [x] STATUS - Get mailbox status information without selecting it.
- [x] COPY - Copy messages to another mailbox.
- [x] MOVE - Move messages to another mailbox.
- [x] EXPUNGE - Expunge deleted messages from the selected mailbox.
- [x] UNSELECT - Allows the client to unselect the current mailbox without selecting a new one.
- [x] GETQUOTA - Retrieve storage quota information.
- [x] GETQUOTAROOT - Retrieve quota information for a mailbox.

#### Message Commands

- [x] FETCH - Fetch headers for messages.
  - [x] FETCH (HEADERS) - Fetch headers for messages.
  - [x] FETCH (PART) - Fetch a specific part of a message.
  - [x] FETCH (STRUCTURE) - Fetch the structure of a message.
- [x] STORE - Store flags on messages.
  - [x] STORE (ADD) - Add flags to messages.
  - [x] STORE (REMOVE) - Remove flags from messages.
 - [x] SEARCH - Allows the client to search for messages based on various criteria.
- [ ] ESEARCH - Extended search command that provides additional search capabilities.

#### TLS Commands

- [x] STARTTLS - Start TLS encryption (used internally in the `startTLS` function).

#### Other Commands

- [ ] ENABLE - Allows the client to enable server-side extensions.
 - [x] ID - Allows the client to identify itself to the server.
- [ ] CONDSTORE - Provides support for conditional STORE operations.
- [ ] QRESYNC - Provides support for quick resynchronization of the mailbox.
- [ ] METADATA - Allows the client to retrieve and store metadata associated with mailboxes.
- [ ] LIST-EXTENDED - Extended LIST command that provides additional listing capabilities.

## SMTP

### Capabilities

- [x] AUTH PLAIN - Used for PLAIN authentication.
- [x] AUTH LOGIN - Used for LOGIN authentication.
- [x] STARTTLS - Used to initiate TLS encryption.
- [x] EHLO - Extended Hello command to fetch server capabilities.
- [ ] DSN - Delivery Status Notification, allows the client to request delivery status notifications for sent emails.
- [ ] ENHANCEDSTATUSCODES - Provides enhanced status codes for more detailed error reporting.
- [ ] BINARYMIME - Allows the transmission of binary MIME messages without the need for encoding.
- [ ] SIZE - Allows the client to specify the size of the message.
- [ ] PIPELINING - Allows the client to send multiple commands without waiting for a response.
- [x] 8BITMIME - Allows the transmission of 8-bit MIME messages.
- [ ] CHUNKING - Allows the client to send large messages in chunks.
- [ ] AUTH CRAM-MD5 - Allows the client to authenticate using the CRAM-MD5 method.
- [ ] AUTH DIGEST-MD5 - Allows the client to authenticate using the DIGEST-MD5 method.

### Commands

#### Connection and Authentication Commands

- [x] EHLO - Fetch server capabilities.
- [x] STARTTLS - Start TLS encryption.
- [x] AUTH PLAIN - Authenticate using PLAIN method.
- [x] AUTH LOGIN - Authenticate using LOGIN method.
- [x] QUIT - Disconnect from the server.

#### Email Sending Commands

- [x] MAIL FROM - Specify the sender's email address.
- [x] RCPT TO - Specify the recipient's email address.
- [x] DATA - Initiate the transfer of the email data.
- [x] SEND CONTENT - Send the actual email content.
