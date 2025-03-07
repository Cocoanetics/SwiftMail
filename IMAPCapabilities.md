# IMAP Capabilities

## Capabilities in Use
- [x] IMAP4rev1
  - Description: The base IMAP4 revision 1 protocol.
- [x] IDLE
  - Description: Allows the server to send real-time updates to the client.
- [x] UIDPLUS
  - Description: Provides additional commands for unique identifiers.
- [x] LITERAL+
  - Description: Allows the use of literals without size limitations.
- [x] SASL-IR
  - Description: Allows initial client response in the first authentication command.
- [x] AUTH=PLAIN
  - Description: Allows plain text authentication.

## Capabilities Not in Use
- [ ] COMPRESS=DEFLATE
  - Description: Allows compression of data streams.
- [ ] ENABLE
  - Description: Allows the client to enable server-side features.
- [ ] CONDSTORE
  - Description: Allows conditional STORE operations.
- [ ] QRESYNC
  - Description: Allows quick resynchronization of the client with the server.
- [ ] ESEARCH
  - Description: Provides extended search capabilities.
- [ ] SEARCHRES
  - Description: Allows the server to return search results.
- [ ] SORT
  - Description: Provides server-side sorting of messages.
- [ ] THREAD
  - Description: Provides server-side threading of messages.
- [ ] XLIST
  - Description: Provides extended list capabilities.
- [ ] X-GM-EXT-1
  - Description: Provides Google-specific IMAP extensions.
