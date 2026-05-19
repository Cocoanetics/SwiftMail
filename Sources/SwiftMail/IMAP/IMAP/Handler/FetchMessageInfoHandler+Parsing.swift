// FetchMessageInfoHandler+Parsing.swift
// Static parsing helpers used by FetchMessageInfoHandler (envelope dates,
// message-ID lists, named time zones).

import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

extension FetchMessageInfoHandler {
    static func shouldCollectThreadingHeaders(for kind: StreamingKind) -> Bool {
        switch kind.sectionSpecifier.kind {
            case .header, .headerFields:
                return true
            default:
                return false
        }
    }

    /// Parse a date string from an IMAP envelope into a `Date`.
    ///
    /// Accepts the standard RFC 5322 forms and additionally tolerates several common
    /// deviations seen in the wild: lowercase month or weekday abbreviations
    /// (e.g. `29 apr 2026 02:14:25`), a missing timezone (interpreted as GMT),
    /// and the obsolete RFC 5322 §4.3 named US time zones (`PST`, `EST`, `PDT`,
    /// etc.) which `DateFormatter`'s `Z` token doesn't recognise.
    ///
    /// Out-of-range numeric fields (e.g. `99 Apr`) are still rejected — strict
    /// parsing is used so corrupted dates surface as `nil` rather than silently
    /// rolling over into a different valid timestamp.
    static func parseEnvelopeDate(_ dateString: String) -> Date? {
        // Strip trailing parenthetical comments such as " (UTC)"
        var cleaned = dateString.replacingOccurrences(
            of: "\\s*\\([^)]+\\)\\s*$",
            with: "",
            options: .regularExpression
        )
        // Substitute named US time zones with their numeric offsets so `Z` can parse them.
        cleaned = normalizeNamedTimeZones(in: cleaned)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",       // RFC 5322
            "EEE, d MMM yyyy HH:mm:ss Z",        // single-digit day
            "d MMM yyyy HH:mm:ss Z",             // no weekday
            "dd MMM yyyy HH:mm:ss Z",            // no weekday, two-digit day
            "EEE, dd MMM yy HH:mm:ss Z",         // two-digit year
            "EEE, dd MMM yyyy HH:mm:ss",         // no timezone
            "EEE, d MMM yyyy HH:mm:ss",
            "d MMM yyyy HH:mm:ss",               // no weekday, no timezone
            "dd MMM yyyy HH:mm:ss"
        ]

        if let date = parseEnvelopeDate(cleaned, formats: formats, formatter: formatter) {
            return date
        }

        // Fallback: capitalize lowercase month/weekday tokens and retry. This
        // handles the case-mismatch deviation without enabling lenient parsing,
        // so out-of-range numeric fields still fail.
        let normalized = normalizeMonthAndWeekdayCase(cleaned)
        if normalized != cleaned {
            return parseEnvelopeDate(normalized, formats: formats, formatter: formatter)
        }
        return nil
    }

    private static func parseEnvelopeDate(_ string: String, formats: [String], formatter: DateFormatter) -> Date? {
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) {
                return date
            }
        }
        return nil
    }

    private static let monthAbbreviations: Set<String> = [
        "jan", "feb", "mar", "apr", "may", "jun",
        "jul", "aug", "sep", "oct", "nov", "dec"
    ]

    private static let weekdayAbbreviations: Set<String> = [
        "mon", "tue", "wed", "thu", "fri", "sat", "sun"
    ]

    private static func normalizeMonthAndWeekdayCase(_ string: String) -> String {
        let tokens = string.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let normalized: [String] = tokens.map { token in
            let stripped = token.trimmingCharacters(in: CharacterSet(charactersIn: ","))
            let lower = stripped.lowercased()
            if monthAbbreviations.contains(lower) || weekdayAbbreviations.contains(lower) {
                return token.capitalized
            }
            return token
        }
        return normalized.joined(separator: " ")
    }

    /// Parse a space/whitespace-separated list of Message-IDs from a References or similar header.
    /// Extracts `<...>` bracketed IDs directly, which handles tabs, folded whitespace, and other
    /// RFC 2822 folding whitespace between IDs.
    static func parseMessageIDs(from value: String) -> [MessageID] {
        // Extract all angle-bracketed tokens — this handles any whitespace between IDs
        var results: [MessageID] = []
        var searchRange = value.startIndex..<value.endIndex
        while let openRange = value.range(of: "<", range: searchRange),
              let closeRange = value.range(of: ">", range: openRange.upperBound..<value.endIndex) {
            let token = String(value[openRange.lowerBound...closeRange.lowerBound])
            if let id = MessageID(token) {
                results.append(id)
            }
            searchRange = closeRange.upperBound..<value.endIndex
        }
        return results
    }

    // MARK: - RFC 5322 obsolete time zone names

    private static let namedZoneOffsets: [String: String] = [
        "UT": "+0000", "GMT": "+0000", "UTC": "+0000",
        "EDT": "-0400", "EST": "-0500",
        "CDT": "-0500", "CST": "-0600",
        "MDT": "-0600", "MST": "-0700",
        "PDT": "-0700", "PST": "-0800",
        "AKDT": "-0800", "AKST": "-0900",
        "HDT": "-0900", "HST": "-1000"
    ]

    /// Replace a trailing alphabetic time zone abbreviation (e.g. ` PST`) with its numeric offset
    /// so DateFormatter's `Z` token can parse it. Returns the input unchanged if the trailing
    /// token isn't a recognised abbreviation.
    static func normalizeNamedTimeZones(in input: String) -> String {
        guard let lastSpaceIndex = input.lastIndex(of: " ") else { return input }
        let zone = String(input[input.index(after: lastSpaceIndex)...]).uppercased()
        guard let offset = namedZoneOffsets[zone] else { return input }
        return String(input[..<lastSpaceIndex]) + " " + offset
    }
}
