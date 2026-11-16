# Getting Started with IMAP

Learn how to use SwiftMail's IMAP functionality to connect to email servers and manage messages.

## Overview

The `IMAPServer` class provides a Swift-native interface for working with IMAP servers. This guide will walk you through the basic steps of connecting to an IMAP server and performing common operations.

## Creating an IMAP Server Instance

First, create an instance of `IMAPServer` with your server details:

```swift
import SwiftMail

let imapServer = IMAPServer(host: "imap.example.com", port: 993)
```

The default port for IMAP over SSL/TLS is 993. For non-SSL connections, use port 143.

## Connecting and Authentication

Connect to the server and authenticate with your credentials:

```swift
try await imapServer.connect()
try await imapServer.login(username: "user@example.com", password: "password")
```

### Cancelling and closing connections

Cancelling a task waiting in the command queue cancels only that operation.
Cancelling an active command closes its transport; other affected callers receive
``IMAPConnectionAbortedError``, and later commands follow the reconnect policy.

Use `await imapServer.abort()` to stop the primary connection, or
`await namedConnection.abort()` to stop one named connection. These calls are
idempotent and nonthrowing, send no DONE or LOGOUT, and require an explicit
`connect()` before further commands. Authenticate and select the mailbox again
after reconnecting (a named handle's `connect()` includes authentication).
`await imapServer.abortAllConnections()` also stops pending named connections and
dedicated IDLE sessions using their existing teardown. Server `connect()` permits
new managed connections again; old named handles still need their own `connect()`.

`disconnect()` closes without waiting for an active command and preserves the
configured reconnect policy for later commands. For graceful protocol completion,
use `logout()` on the server, or `done()` to end IDLE.

## Working with Mailboxes

List available mailboxes and select one to work with:

```swift
// List mailboxes
let mailboxes = try await imapServer.listMailboxes()
for mailbox in mailboxes {
    print("📬 \(mailbox.name)")
}

// Select a mailbox
let mailboxInfo = try await imapServer.selectMailbox("INBOX")
print("Mailbox contains \(mailboxInfo.messageCount) messages")

// Note: The SELECT command does not provide an unseen count
// Use mailboxStatus("INBOX").unseenCount or search for unseen messages instead
```

By default `listMailboxes()` uses the `"*"` wildcard, but you can specify a
different pattern if needed:

```swift
// Only list top-level mailboxes
let mailboxes = try await imapServer.listMailboxes(wildcard: "%")
```

### Resynchronizing with QRESYNC

QRESYNC can return mailbox metadata, vanished UIDs, and complete flag updates
in one selection. Enable it after authentication and before any SELECT on that
connection. ENABLE state is connection-local, so enable it again after a
replacement connection is established.

```swift
let advertised = try await imapServer.fetchCapabilities()
guard advertised.contains(where: { String($0).uppercased() == "ENABLE" }),
      advertised.contains(where: { String($0).uppercased() == "QRESYNC" }) else {
    throw IMAPError.commandNotSupported("QRESYNC is unavailable")
}

let enabled = try await imapServer.enable([.qresync, .condStore])
guard enabled.contains(.qresync) else {
    throw IMAPError.commandNotSupported("The server did not enable QRESYNC")
}

let storedValidity: UIDValidity = 777
let changes = try await imapServer.selectMailbox(
    "INBOX",
    resyncingFrom: storedValidity,
    modificationSequence: 900
)

guard changes.selection.uidValidity == storedValidity else {
    discardStoredCheckpoint()
    discardStoredMessages()
    try await synchronizeNormally()
    return
}

guard let checkpoint = changes.selection.highestModSequence else {
    // NOMODSEQ or an omitted checkpoint requires ordinary synchronization.
    discardStoredCheckpoint()
    try await synchronizeNormally()
    return
}

for vanishedRange in changes.vanishedEarlier.ranges {
    removeStoredMessages(in: vanishedRange)
}
for vanishedRange in changes.vanished.ranges {
    removeStoredMessages(in: vanishedRange)
}
for (uid, flags) in changes.changedFlags {
    replaceStoredFlags(for: uid, with: flags)
}

saveCheckpoint(checkpoint)
```

The storage functions and `synchronizeNormally()` above belong to your app.
SwiftMail does not persist checkpoints or fall back automatically. Validate
UIDVALIDITY first, then require a `highestModSequence` before applying the
incremental result. A nil value means the server sent NOMODSEQ or omitted the
checkpoint. In either case, discard the stored modification-sequence checkpoint
and use ordinary synchronization. NOMODSEQ requires removing the cached
HIGHESTMODSEQ as described in [RFC 7162 section 6](https://www.rfc-editor.org/rfc/rfc7162.html#section-6).

Apply both deletion sets before replacing each message's complete flag set.
`vanishedEarlier` contains historical deletions and does not reduce the returned
message count. `vanished` contains live deletions during selection. The returned
`selection.messageCount` already accounts for live deletions and EXISTS responses
in arrival order, so do not subtract either set from it. A later EXISTS replaces
the count. `changedFlags` excludes UIDs in either deletion set.

### Flag changes with CONDSTORE

A server that advertises CONDSTORE but not QRESYNC can still report which
messages changed since a stored HIGHESTMODSEQ. Select the mailbox with the
CONDSTORE parameter (this needs no ENABLE), check UIDVALIDITY and the
modification sequence, then fetch the changed flags:

```swift
let selection = try await imapServer.selectMailbox("INBOX", enablingCondStore: true)
guard selection.uidValidity == storedValidity,
      let highest = selection.highestModificationSequenceValue else {
    // A new UIDVALIDITY, or NOMODSEQ: discard the stored checkpoint.
    try await synchronizeNormally()
    return
}

// The lowest to the highest UID your app holds for this mailbox. A contiguous
// range keeps the command line short; a long, sparse UID set can exceed the
// server's line limit (RFC 7162 section 4).
let changes = try await imapServer.fetchFlagsChangedSince(
    UIDSet(lowestStoredUID...highestStoredUID),
    modificationSequence: storedModificationSequence
)
for change in changes {
    replaceStoredFlags(for: change.uid, with: change.flags)
}
saveCheckpoint(highest)
```

Each result holds the message's complete flag set and its MODSEQ. An empty
result means no message in the set changed. `UIDSet(UID(1)...)`, sent as `1:*`,
asks about every message; any other set holding `UID.latest` throws
`invalidArgument`, because the server reads `n:*` as the highest UID alone when
`n` is above it (RFC 3501 section 6.4.8). CHANGEDSINCE reports only messages
that still exist; finding expunged messages is up to the client (for example by
comparing message counts or with UID SEARCH), since without QRESYNC the server
does not report them. A plain SELECT reports HIGHESTMODSEQ only after a
CONDSTORE enabling command (RFC 7162 section 3.1.2.1), so a connection that
already ran `enable([.condStore])` can use a plain SELECT. The fetch is itself an
enabling command and never needs ENABLE first.

## Fetching Messages

Fetch messages from the selected mailbox. By default these methods fetch only the first message to keep payloads small. For large mailboxes you can
stream messages one by one and cancel early if needed:

```swift
// Get the latest 10 messages
if let latestMessagesSet = mailboxInfo.latest(10) {
    for try await email in imapServer.fetchMessages(using: latestMessagesSet) {
        print("Fetched message #\(email.sequenceNumber)")
    }
}
```
If you prefer to receive all messages at once, you can still use
``fetchMessages(using:)`` which collects the stream into an array.

You can also stream message headers without fetching bodies:

```swift
// Stream headers for the latest 10 messages
if let latestMessagesSet = mailboxInfo.latest(10) {
    for try await header in imapServer.fetchMessageInfos(using: latestMessagesSet) {
        print("Header: \(header.subject ?? \"No subject\")")
    }
}
```

When you need header lines exactly as the message carries them, such as every
`Received` or `Authentication-Results` field in order or the raw `Reply-To`,
fetch the raw header block for the named fields. This sends
`UID FETCH ... BODY.PEEK[HEADER.FIELDS (...)]`, one command per 200 messages
(`chunkSize:` changes that, `timeoutSeconds:` each command's deadline), and
leaves `\Seen` alone:

```swift
let blocks = try await imapServer.fetchHeaderFields(
    ["Reply-To", "Delivered-To", "Authentication-Results"],
    using: UIDSet(uidRange)
)
// blocks[uid] holds the matching lines, topmost first, as the server sent them
```

## Searching Messages

SwiftMail provides powerful search capabilities using different types of message identifiers:

```swift
// Define message identifier set types for searching
let unreadMessagesSet: MessageIdentifierSet<SequenceNumber> // Uses temporary sequence numbers
let sampleMessagesSet: MessageIdentifierSet<UID> // Uses permanent unique identifiers

// Search for unread messages using sequence numbers
print("\nSearching for unread messages...")

// Method 1: Using STATUS for unseen count (doesn't require selection)
let statusUnseenCount = try await imapServer.mailboxStatus("INBOX").unseenCount ?? 0
print("Found \(statusUnseenCount) unread messages (using STATUS unseenCount)")

// Method 2: Using search directly
unreadMessagesSet = try await imapServer.search(criteria: [.unseen])
print("Found \(unreadMessagesSet.count) unread messages (using search)")

// Method 3: Using STATUS command to get multiple attributes
// Important: Call mailboxStatus before selecting a mailbox or after unselect/close to
// avoid server warnings like: OK [CLIENTBUG] Status on selected mailbox
let mailboxStatus = try await imapServer.mailboxStatus("INBOX")
print("Mailbox status: \(mailboxStatus)")
print("   - Message count: \(mailboxStatus.messageCount ?? 0)")
print("   - Unseen count: \(mailboxStatus.unseenCount ?? 0)")
print("   - Recent count: \(mailboxStatus.recentCount ?? 0)")

// Method 4: Using STATUS command to get multiple attributes
let mailboxStatus = try await imapServer.mailboxStatus("INBOX")
print("Mailbox status: \(mailboxStatus)")
print("   - Message count: \(mailboxStatus.messageCount ?? 0)")
print("   - Unseen count: \(mailboxStatus.unseenCount ?? 0)")
print("   - Recent count: \(mailboxStatus.recentCount ?? 0)")

// Search for messages with a specific subject using UIDs
print("\nSearching for sample emails...")
sampleMessagesSet = try await imapServer.search(criteria: [.subject("SwiftSMTPCLI")])
print("Found \(sampleMessagesSet.count) sample emails")
```

The search functionality supports two types of message identifiers:
- **SequenceNumber**: Temporary numbers assigned to messages in a mailbox that change frequently
- **UID**: Message identifiers that are more stable than sequence numbers but can still change between sessions or when the mailbox is modified

Common search criteria include:
- `.unseen`: Find unread messages
- `.subject(String)`: Search by subject text
- `.from(String)`: Search by sender
- `.to(String)`: Search by recipient
- `.before(Date)`: Find messages before a date
- `.since(Date)`: Find messages since a date

## Extended Search (ESEARCH)

When you need aggregate metadata — total count, lowest/highest UID, or the full matching set — use `extendedSearch(...)` instead of `search(...)`.

`extendedSearch` automatically uses the server's ESEARCH extension (RFC 4731) when available and transparently falls back to a plain SEARCH otherwise, so callers always receive an ``ExtendedSearchResult`` regardless of server capability.

```swift
// Count unread messages without fetching their identifiers
let result: ExtendedSearchResult<UID> = try await imapServer.extendedSearch(criteria: [.unseen])
print("Unread count: \(result.count ?? 0)")

// Find the oldest and newest unread UIDs in one round-trip
if let oldest = result.min, let newest = result.max {
    print("Unread UIDs span \(oldest.value) – \(newest.value)")
}

// Scope a search to a previously fetched set of messages
let recentUIDs: UIDSet = // … your set …
let scopedResult: ExtendedSearchResult<UID> = try await imapServer.extendedSearch(
    identifierSet: recentUIDs,
    criteria: [.unseen]
)
print("Unread in recent batch: \(scopedResult.all?.count ?? 0)")
```

**When to prefer `extendedSearch` over `search`:**
- You need COUNT, MIN, or MAX without downloading all matching identifiers.
- You want a single, typed result struct instead of a raw ``MessageIdentifierSet``.
- You are searching a scoped subset of messages (pass `identifierSet:`).
- You want paged results without fetching the entire match list (pass `partialRange:`).

**When `search` is sufficient:**
- You only need the set of matching identifiers and don't require aggregate fields.
- The server is known to lack ESEARCH support and you want to avoid the capability check overhead.

### Paged results with PARTIAL

Pass a ``PartialRange`` to retrieve a window of results instead of the full match list
(requires ESEARCH plus `PARTIAL` or `CONTEXT=SEARCH`, or for a sorted search ESORT plus `CONTEXT=SORT`;
silently ignored on servers without it):

```swift
// Get the first 100 matching UIDs
let first100 = try await imapServer.extendedSearch(
    criteria: [.unseen],
    partialRange: .first(1...100)
)
if let page = first100.partial {
    print("Page \(page.range): \(page.results.count) UIDs")
}

// Get the last 50 matching UIDs
let last50 = try await imapServer.extendedSearch(
    criteria: [.unseen],
    partialRange: .last(1...50)
)
```

When `partialRange` is set and the server supports it, `PARTIAL` is requested instead of
`ALL`, and the result appears in ``ExtendedSearchResult/partial`` rather than
``ExtendedSearchResult/all``.

Some servers (Gmail, iCloud) advertise ESEARCH without PARTIAL and reject the option. For those,
SwiftMail drops the window and requests `ALL`, so ``ExtendedSearchResult/partial`` is `nil` and
you page client-side from ``ExtendedSearchResult/all`` (or ``ExtendedSearchResult/ordered`` when
`sortCriteria` is set, since the search then falls back to a plain `SORT`):

```swift
let uids = result.partial?.results.toArray() ?? Array(result.all?.toArray().prefix(100) ?? [])
```

## Getting Mailbox Status

You can get status information about mailboxes without selecting them using the STATUS command.
Important: Call it when no mailbox is selected (before SELECT) or after UNSELECT/CLOSE to
avoid warnings like `OK [CLIENTBUG] Status on selected mailbox` on some servers:

```swift
// Get the unseen count and other status attributes for a specific mailbox
let status = try await imapServer.mailboxStatus("INBOX")
print("Mailbox has \(status.messageCount ?? 0) messages, \(status.unseenCount ?? 0) unread")
```

The STATUS command is more efficient than SELECT when you only need status information, as it doesn't change the currently selected mailbox.

## Error Handling

SwiftMail uses Swift's error handling system. Common errors include:
- Network connectivity issues
- Authentication failures
- Invalid mailbox names
- Server timeouts

Always wrap IMAP operations in try-catch blocks:

```swift
do {
    try await imapServer.connect()
    try await imapServer.login(username: "user@example.com", password: "password")
} catch {
    print("IMAP error: \(error)")
}
```

## Cleanup

Always remember to properly close your connection:

```swift
// Logout from the server
try await imapServer.logout()

// Close the connection
try await imapServer.close()
```

## Special Mailboxes

SwiftMail provides easy access to common special-use mailboxes:

```swift
// Get standard mailboxes
let inbox = try imapServer.inboxFolder
let sent = try imapServer.sentFolder
let trash = try imapServer.trashFolder
let drafts = try imapServer.draftsFolder
let junk = try imapServer.junkFolder
let archive = try imapServer.archiveFolder
```

## Message Operations

### Copying Messages

Copy messages between mailboxes:

```swift
// Copy messages using sequence numbers or UIDs
let messageSet: MessageIdentifierSet<UID> = // ... your message set ...
try await imapServer.copy(messageSet, to: "Archive")
```

### Managing Message Flags

Set or remove flags on messages:

```swift
// Mark messages as read
let unreadSet: MessageIdentifierSet<UID> = // ... your message set ...
try await imapServer.store(unreadSet, flags: [.seen], operation: .add)

// Mark messages as deleted
let messageSet: MessageIdentifierSet<UID> = // ... your message set ...
try await imapServer.store(messageSet, flags: [.deleted], operation: .add)
```

### Expunging Deleted Messages

Remove messages marked for deletion:

```swift
// Permanently remove messages marked as deleted
try await imapServer.expunge()
```

### Creating Draft Messages

Compose a new ``Email`` and store it directly in the Drafts mailbox without going through SMTP:

```swift
let draft = Email(
    sender: EmailAddress(name: "Me", address: "me@example.com"),
    recipients: [],
    subject: "Follow up",
    textBody: "Add more details here."
)

let appendResult = try await imapServer.createDraft(from: draft)
if let uid = appendResult.firstUID {
    print("Draft stored with UID \(uid.value)")
}
```

Need to target a different mailbox or control the flags? Use the lower-level helper:

```swift
try await imapServer.append(
    email: draft,
    to: "Ideas/Drafts",
    flags: [.seen]
)
```

## Mailbox Management

### Closing a Mailbox

Close the currently selected mailbox:

```swift
// Close mailbox and expunge deleted messages
try await imapServer.closeMailbox()

// Close mailbox without expunging (if supported by server)
try await imapServer.unselectMailbox()
```

## Next Steps

- Learn more about IMAP operations in <doc:WorkingWithIMAP>
- Explore the ``IMAPServer`` API documentation
- Check out the demo apps in the repository

## Topics

- ``IMAPServer``
