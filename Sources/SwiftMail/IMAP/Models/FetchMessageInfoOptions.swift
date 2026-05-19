// FetchMessageInfoOptions.swift
// Selects which IMAP FETCH attributes to request when populating a `MessageInfo`.

import Foundation

/// Per-message attributes to request when fetching `MessageInfo`. UID is always implicit.
///
/// Use this to trade per-message payload weight against the metadata you actually need.
/// The default `.default` set matches what `MessageInfo` historically populated; `.slim`
/// and `.uidFlagsOnly` strip out the expensive attributes so large mailboxes fit inside
/// the per-command 10s timeout.
public struct FetchMessageInfoOptions: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Request `ENVELOPE` (subject, from/to/cc/bcc, date, Message-ID, In-Reply-To).
    public static let envelope      = FetchMessageInfoOptions(rawValue: 1 << 0)

    /// Request `INTERNALDATE` (server-side delivery timestamp).
    public static let internalDate  = FetchMessageInfoOptions(rawValue: 1 << 1)

    /// Request `FLAGS`.
    public static let flags         = FetchMessageInfoOptions(rawValue: 1 << 2)

    /// Request `RFC822.SIZE` (total octets of the message).
    public static let size          = FetchMessageInfoOptions(rawValue: 1 << 3)

    /// Request `BODYSTRUCTURE` (MIME tree). Roughly an order of magnitude larger than the
    /// other attributes for non-trivial messages.
    public static let bodyStructure = FetchMessageInfoOptions(rawValue: 1 << 4)

    /// Request the full header section via `BODY.PEEK[HEADER]`. Includes everything the
    /// envelope already exposes plus all additional headers.
    public static let fullHeader    = FetchMessageInfoOptions(rawValue: 1 << 5)

    /// Default attribute set used by `fetchMessageInfo(s)` when no options are passed —
    /// matches the historical behaviour: envelope, internal date, flags, body structure
    /// and the full header section.
    public static let `default`: FetchMessageInfoOptions = [
        .envelope, .internalDate, .flags, .bodyStructure, .fullHeader
    ]

    /// Slim attribute set for large-mailbox listing / newsletter triage: envelope,
    /// internal date, flags and size. No body structure, no header section. Roughly
    /// 25× smaller per message than `.default`.
    ///
    /// Pair with `headerFields: FetchMessageInfoOptions.newsletterHeaderFields` to also
    /// surface `List-Unsubscribe` and related auto-mail signals.
    public static let slim: FetchMessageInfoOptions = [
        .envelope, .internalDate, .flags, .size
    ]

    /// Smallest possible per-message payload — just flags (UID is always included).
    /// Designed for incremental-sync diffing where the caller only needs to know which
    /// UIDs are still on the server and their flag state.
    public static let uidFlagsOnly: FetchMessageInfoOptions = [.flags]

    /// Header fields commonly paired with `.slim` for newsletter / auto-mail detection.
    /// Tiny per-message cost (~200 bytes) when requested via `BODY.PEEK[HEADER.FIELDS (...)]`.
    public static let newsletterHeaderFields: [String] = [
        "List-Unsubscribe",
        "List-Unsubscribe-Post",
        "List-ID",
        "Auto-Submitted",
        "Precedence"
    ]

    /// Default streaming chunk size derived from per-message payload weight. Lighter
    /// payloads → larger chunks → fewer round-trips for the same total fetch.
    ///
    /// - `.uidFlagsOnly` → 5000 (~50 bytes per message; tens of thousands fit in one command).
    /// - Anything pulling `.bodyStructure` or `.fullHeader` → 50 (current default; stays inside
    ///   the 10s per-command timeout for typical messages).
    /// - Everything else (slim-ish sets) → 500 (~order of magnitude smaller per message).
    var suggestedChunkSize: Int {
        if self == .uidFlagsOnly { return 5000 }
        if contains(.bodyStructure) || contains(.fullHeader) { return 50 }
        return 500
    }
}
