// EMLParser+AddressAndDate.swift
// Helpers for splitting address fields and parsing RFC 2822 dates.

import Foundation

extension EMLParser {

    // MARK: - Address Parsing

    /// Split an address field into its addresses, each in the text it was
    /// written with: display names stay in wire form, and a group, members
    /// included, stays one element. Malformed text is kept as its own element
    /// rather than dropped; ``AddressParser`` decides where it ends.
    static func parseAddressList(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return AddressParser.parseEntries(value).map(\.source)
    }

    // MARK: - Date Parsing

    /// Parse an RFC 2822 date string.
    static func parseRFC2822Date(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",       // Standard RFC 2822
            "EEE, d MMM yyyy HH:mm:ss Z",        // Single-digit day
            "dd MMM yyyy HH:mm:ss Z",            // No day name
            "d MMM yyyy HH:mm:ss Z",             // No day name, single-digit day
            "EEE, dd MMM yyyy HH:mm:ss ZZZZ",    // Named timezone
            "EEE, d MMM yyyy HH:mm:ss ZZZZ",
            "EEE, dd MMM yy HH:mm:ss Z"         // Two-digit year
        ]

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        // Try ISO 8601 as fallback
        let iso = ISO8601DateFormatter()
        return iso.date(from: trimmed)
    }
}
