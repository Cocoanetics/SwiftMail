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

1. **Scope to what SwiftMail can see.** If a feature can only be guaranteed
   fully inside the parser, SwiftMail implements the part it can enforce from
   the response events NIOIMAP delivers. It then documents the remaining limit
   honestly. Example: FETCH payload budgets count streamed sections, while
   literals nested in ENVELOPE/BODYSTRUCTURE stay bounded by the per-response
   parser limits (#291, #294).
2. **Surface invalid server data; never quietly fix it up.** When a server sends
   something invalid, SwiftMail reports it as a typed error or an explicit
   invalid value. It never silently repairs, reshapes or drops the data. Crash
   paths such as unbounded recursion are still avoided.
3. **swift-nio-imap's own defects are accepted upstream risks.** A crash or data
   loss that lives inside swift-nio-imap does not block a SwiftMail change. We
   pick up the fix when it ships upstream; we don't work around it with a fork.
   Problems we find are reported upstream as proposals, for example
   apple/swift-nio-imap#859.
4. **Opt-in and source-compatible.** New limits, budgets and behaviours are opt-in
   with defaults that keep existing callers working. Breaking changes need a
   strong reason and a major version.
5. **Plan in pieces that can each merge.** Large requests are split into
   pull-request-sized sub-issues. Each one ships with its own tests and stands
   on its own, the way #292 was split into #300–#304. A plan whose prerequisite
   sits outside this repository gets descoped, not left blocked.
6. **Deterministic tests.** Wire behaviour is tested against the real NIOIMAP
   decoder (embedded channels) and the gated local socket fixture. Tests never
   rely on sleeps or live servers to establish ordering.
