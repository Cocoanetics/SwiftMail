# SwiftMail Vision

SwiftMail gives Swift apps a pleasant, modern way to use IMAP, SMTP and MIME. It
should feel like a native Swift API (async/await, typed results, typed errors),
work the same on every platform Swift runs on, and stay small enough that one
maintainer can keep it correct.

This page is for anyone deciding what SwiftMail should or should not take on:
contributors, reviewers, and the project manager who triages and plans issues.

## What SwiftMail is

- **A nice wrapper around swift-nio-imap.** On the IMAP side, SwiftMail is a
  wrapper around [swift-nio-imap](https://github.com/apple/swift-nio-imap) and
  nothing more. It handles connections, authentication, command queuing,
  reconnects and IDLE. It turns NIOIMAP's grammar types into friendly models
  such as `MessageInfo`, `Message` and mailbox listings, and it gives callers
  ergonomic APIs on top. Callers should never need to import or handle NIO
  types.
- **An SMTP client** built on swift-nio and swift-nio-ssl.
- **A MIME and message-content library**: parsing and building messages,
  charsets, RFC 2047/2231 encoding, attachments, `.eml` and Outlook `.msg`.
  swift-nio-imap does not cover message content, so this is SwiftMail's own
  domain.
- **Cross-platform**: macOS, iOS and the other Apple platforms, Linux and
  Android. Windows is experimental: swift-nio now builds there, but
  swift-nio-ssl does not yet (apple/swift-nio-ssl#567).

## What SwiftMail is not

- **Not an IMAP protocol implementation.** IMAP parsing and command-level
  communication belong to swift-nio-imap. That covers encoding commands,
  decoding responses, the grammar, the parser and decoder, and any hooks inside
  them. SwiftMail never duplicates something swift-nio-imap already provides,
  unless the duplicate exists only to give it an elegant, modern Swift facade.
  Public SwiftMail enums, structs and errors that mirror NIOIMAP concepts are
  welcome when they keep NIO types out of SwiftMail's public API. SwiftMail does
  not re-implement or patch IMAP parsing, does not fork or vendor
  swift-nio-imap, and does not plan work that needs a new nio-imap API before
  that API exists upstream.
- **Not a hardened gateway for hostile servers.** Mail servers are treated as
  non-adversarial but fallible. Reasonable resource limits are welcome, such as
  the existing `IMAPParserLimits`, LIST limits, timeouts and opt-in budgets.
  Elaborate defences against a malicious server are out of scope.
- **Not a mail client.** SwiftMail does not offer sync engines, local storage,
  threading UIs or account management. It gives apps the building blocks to
  write those themselves.

## Principles for planning and review

### Scope and planning

1. **Scope to what SwiftMail can see.** If a feature can only be guaranteed
   fully inside the parser, SwiftMail implements the part it can enforce from
   the response events NIOIMAP delivers. It then documents the remaining limit
   honestly. Example: FETCH payload budgets count streamed sections, while
   literals nested in ENVELOPE/BODYSTRUCTURE stay bounded by the per-response
   parser limits (#291, #294).
2. **Upstream first.** When a gap is in swift-nio-imap, the outcome is an
   upstream issue or pull request, proposed to the maintainer for approval
   before anything is filed. SwiftMail adopts the change once it ships upstream.
   Until then, a crash or data loss that lives inside swift-nio-imap is an
   accepted risk and does not block a SwiftMail change. Example:
   apple/swift-nio-imap#859.
3. **Keep plans proportional to demonstrated need.** A request based only on
   source inspection gets a small, direct fix. A large plan needs a
   reproduction or an observation against a real server first. A plan that
   would take more than a few pull requests needs the maintainer's sign-off
   before its sub-issues are created.
4. **Plan in pieces that can each merge.** Large requests are split into
   pull-request-sized sub-issues. Each one ships with its own tests and stands
   on its own, the way #292 was split into #300–#304. A plan whose prerequisite
   sits outside this repository gets descoped, not left blocked.

### Handling mail data

5. **Own domain, done properly.** MIME, addresses, charsets and SMTP have no
   upstream, so SwiftMail owns their parsing. Each format has exactly one
   parser, working at the byte level, as with the single RFC 5322 address
   parser (#245).
6. **Strict with servers, tolerant with senders.** Mail servers are fallible
   but not hostile. When a server sends invalid protocol data, SwiftMail
   reports it as a typed error or an explicit invalid value. It never silently
   repairs, reshapes or drops it. Sender-written content is different: headers,
   filenames and charsets are read the way real mail is actually written, as
   long as nothing is lost. Crash paths such as unbounded recursion are avoided
   in both cases.
7. **Lossless by default.** SwiftMail never drops or alters mail data. Bcc in
   drafts, repeated header fields and raw message bytes all survive a round
   trip. A convenience API may simplify, but the exact original stays
   reachable.
8. **Only use what the server advertises.** An IMAP or SMTP extension is used
   only when the server advertises the capability, with a fallback where one
   exists (COPY and delete for MOVE, plain SEARCH for ESEARCH PARTIAL). Gmail,
   iCloud, Dovecot and Exchange are the reference servers, as in the README's
   capability table.

### API and quality

9. **Opt-in and source-compatible.** New limits, budgets and behaviours are
   opt-in with defaults that keep existing callers working. Breaking changes
   need a strong reason and a major version.
10. **Parity and definition of done.** A public IMAP feature is available on
    both the primary and named connections. It is done when it has tests and
    DocC comments, and the README capability table is updated where relevant.
11. **Deterministic tests.** Wire behaviour is tested against the real NIOIMAP
    decoder (embedded channels) and the gated local socket fixture. Tests never
    rely on sleeps or live servers to establish ordering.
