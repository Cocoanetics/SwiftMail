// EMLParser+AddressAndDate.swift
// Helpers for parsing comma-separated address lists and RFC 2822 dates.

import Foundation

extension EMLParser {

    // MARK: - Address Parsing

    /// Parse a comma-separated list of email addresses.
    static func parseAddressList(_ value: String?) -> [String] {
        guard let value = value, !value.isEmpty else { return [] }

        // Split by comma, but respect quoted strings and angle brackets
        var addresses: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false

        for char in value {
            switch char {
            case "\"":
                inQuotes.toggle()
                current.append(char)
            case "<":
                inAngle = true
                current.append(char)
            case ">":
                inAngle = false
                current.append(char)
            case "," where !inQuotes && !inAngle:
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    addresses.append(decodeRFC2047(trimmed) ?? trimmed)
                }
                current = ""
            default:
                current.append(char)
            }
        }

        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            addresses.append(decodeRFC2047(trimmed) ?? trimmed)
        }

        return addresses
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
