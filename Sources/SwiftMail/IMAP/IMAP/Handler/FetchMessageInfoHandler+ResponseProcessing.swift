// FetchMessageInfoHandler+ResponseProcessing.swift
// Response-processing helpers for FetchMessageInfoHandler split out to keep the
// main type body within the SwiftLint `type_body_length` limit.

import Foundation
import NIO
@preconcurrency import NIOIMAP
import NIOIMAPCore

extension FetchMessageInfoHandler {
    /// Process a fetch response
    /// - Parameter fetchResponse: The fetch response to process
    func processFetchResponse(_ fetchResponse: FetchResponse) {
        switch fetchResponse {
            case let .simpleAttribute(attribute):
                // Process simple attributes (no sequence number)
                processMessageAttribute(attribute, sequenceNumber: nil)

            case let .start(sequenceNumber):
                // Create a new header for this sequence number
                currentSequenceNumber = SequenceNumber(sequenceNumber.rawValue)
                currentHeaderLiteral.removeAll(keepingCapacity: true)
                collectingThreadingHeaders = false
                let messageInfo = MessageInfo(sequenceNumber: SequenceNumber(sequenceNumber.rawValue))
                lock.withLock {
                    self.messageInfos.append(messageInfo)
                }

            case let .streamingBegin(kind, _):
                collectingThreadingHeaders = Self.shouldCollectThreadingHeaders(for: kind)
                if collectingThreadingHeaders {
                    currentHeaderLiteral.removeAll(keepingCapacity: true)
                }

            case let .streamingBytes(data):
                guard collectingThreadingHeaders else { break }
                currentHeaderLiteral.append(contentsOf: data.readableBytesView)

            case .streamingEnd:
                guard collectingThreadingHeaders else { break }
                applyCollectedThreadingHeaders()
                collectingThreadingHeaders = false
                currentHeaderLiteral.removeAll(keepingCapacity: true)

            case .finish:
                currentSequenceNumber = nil
                collectingThreadingHeaders = false
                currentHeaderLiteral.removeAll(keepingCapacity: true)

            default:
                break
        }
    }

    func applyCollectedThreadingHeaders() {
        let utf8Block = String(data: currentHeaderLiteral, encoding: .utf8)
        let asciiBlock = String(data: currentHeaderLiteral, encoding: .ascii)
        guard let headerBlock = utf8Block ?? asciiBlock else { return }

        let allHeaders = EMLParser.parseHeaders(headerBlock)

        // Headers already exposed via ENVELOPE or stored in dedicated fields
        let envelopeKeys: Set = [
            "from", "to", "cc", "bcc", "subject", "date",
            "message-id", "in-reply-to", "references", "reply-to"
        ]

        let referencesValue = allHeaders["references"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let additionalHeaders = allHeaders.filter { !envelopeKeys.contains($0.key) }

        lock.withLock {
            guard let index = currentMessageIndex() else { return }
            var header = self.messageInfos[index]

            if let references = referencesValue, !references.isEmpty {
                let parsed = Self.parseMessageIDs(from: references)
                header.references = parsed.isEmpty ? nil : parsed
            }

            header.additionalFields = additionalHeaders.isEmpty ? nil : additionalHeaders
            self.messageInfos[index] = header
        }
    }

    private func currentMessageIndex() -> Int? {
        if let currentSequenceNumber,
           let index = messageInfos.firstIndex(where: { $0.sequenceNumber == currentSequenceNumber }) {
            return index
        }

        return messageInfos.indices.last
    }

    /// Process a message attribute and update the corresponding email header
    /// - Parameters:
    ///   - attribute: The message attribute to process
    ///   - sequenceNumber: The sequence number of the message (if known)
    func processMessageAttribute(_ attribute: MessageAttribute, sequenceNumber: SequenceNumber?) {
        // If we don't have a sequence number, we can't update a header
        guard let sequenceNumber else {
            // For attributes that come without a sequence number, we assume they belong to the last header
            lock.withLock {
                if let lastIndex = self.messageInfos.indices.last {
                    var header = self.messageInfos[lastIndex]
                    updateHeader(&header, with: attribute)
                    self.messageInfos[lastIndex] = header
                }
            }
            return
        }

        // Find or create a header for this sequence number
        let seqNum = SequenceNumber(sequenceNumber.value)
        lock.withLock {
            if let index = self.messageInfos.firstIndex(where: { $0.sequenceNumber == seqNum }) {
                var header = self.messageInfos[index]
                updateHeader(&header, with: attribute)
                self.messageInfos[index] = header
            } else {
                var header = MessageInfo(sequenceNumber: seqNum)
                updateHeader(&header, with: attribute)
                self.messageInfos.append(header)
            }
        }
    }

    /// Update an email header with information from a message attribute
    /// - Parameters:
    ///   - header: The header to update
    ///   - attribute: The attribute containing the information
    private func updateHeader(_ header: inout MessageInfo, with attribute: MessageAttribute) {
        switch attribute {
            case let .envelope(envelope):
                applyEnvelope(envelope, to: &header)
            case let .uid(uid):
                header.uid = UID(nio: uid)
            case let .internalDate(serverDate):
                applyInternalDate(serverDate, to: &header)
            case let .flags(flags):
                header.flags = flags.map(Self.convertFlag)
            case let .body(bodyStructure, _):
                if case let .valid(structure) = bodyStructure {
                    header.parts = [MessagePart](structure)
                }
            default:
                break
        }
    }

    /// Apply envelope information to an email header.
    private func applyEnvelope(_ envelope: Envelope, to header: inout MessageInfo) {
        // Extract information from envelope
        if let subject = envelope.subject?.stringValue {
            header.subject = subject.decodeMIMEHeader()
        }

        // Handle from addresses - check if array is not empty
        if !envelope.from.isEmpty {
            header.from = Self.formatAddress(envelope.from[0])
        }

        // Handle to addresses - capture all recipients
        header.to = envelope.to.map { Self.formatAddress($0) }

        // Handle cc addresses - capture all recipients
        header.cc = envelope.cc.map { Self.formatAddress($0) }

        // Handle bcc addresses - capture all recipients
        header.bcc = envelope.bcc.map { Self.formatAddress($0) }

        if let date = envelope.date {
            let dateString = String(date)
            if let parsedDate = Self.parseEnvelopeDate(dateString) {
                header.date = parsedDate
            } else {
                print("Warning: Failed to parse email date: \(dateString)")
            }
        }

        if let messageID = envelope.messageID {
            header.messageId = MessageID(String(messageID))
        }

        if let inReplyTo = envelope.inReplyTo {
            header.inReplyTo = MessageID(String(inReplyTo))
        }
    }

    /// Apply an INTERNALDATE attribute to an email header.
    private func applyInternalDate(_ serverDate: ServerMessageDate, to header: inout MessageInfo) {
        let dateValues = serverDate.components
        var components = DateComponents()
        components.year = dateValues.year
        components.month = dateValues.month
        components.day = dateValues.day
        components.hour = dateValues.hour
        components.minute = dateValues.minute
        components.second = dateValues.second
        components.timeZone = Foundation.TimeZone(secondsFromGMT: dateValues.zoneMinutes * 60)
        if let date = Calendar(identifier: .gregorian).date(from: components) {
            header.internalDate = date
        }
    }

    // MARK: - Static helpers

    /// Convert a NIOIMAPCore.Flag to our MessageFlag type
    static func convertFlag(_ flag: NIOIMAPCore.Flag) -> Flag {
        let flagString = String(flag)

        switch flagString.uppercased() {
            case "\\SEEN":
                return .seen
            case "\\ANSWERED":
                return .answered
            case "\\FLAGGED":
                return .flagged
            case "\\DELETED":
                return .deleted
            case "\\DRAFT":
                return .draft
            default:
                // For any other flag, treat it as a custom flag
                return .custom(flagString)
        }
    }

    /// Format an address for display
    /// - Parameter address: The address to format
    /// - Returns: A formatted string representation of the address
    static func formatAddress(_ address: EmailAddressListElement) -> String {
        switch address {
            case let .singleAddress(emailAddress):
                let name = emailAddress.personName?.stringValue.decodeMIMEHeader() ?? ""
                let mailbox = emailAddress.mailbox?.stringValue ?? ""
                let host = emailAddress.host?.stringValue ?? ""

                if !name.isEmpty {
                    return "\"\(name)\" <\(mailbox)@\(host)>"
                } else {
                    return "\(mailbox)@\(host)"
                }

            case let .group(group):
                let groupName = group.groupName.stringValue.decodeMIMEHeader()
                let members = group.children.map { formatAddress($0) }.joined(separator: ", ")
                return "\(groupName): \(members)"
        }
    }

    static func shouldCollectThreadingHeaders(for kind: StreamingKind) -> Bool {
        kind.sectionSpecifier.kind == .header
    }

    /// Parse a date string from an IMAP envelope into a `Date`.
    ///
    /// Accepts the standard RFC 5322 forms and additionally tolerates several common
    /// deviations seen in the wild: lowercase month or weekday abbreviations
    /// (e.g. `29 apr 2026 02:14:25`) and a missing timezone (interpreted as GMT).
    ///
    /// Out-of-range numeric fields (e.g. `99 Apr`) are still rejected — strict
    /// parsing is used so corrupted dates surface as `nil` rather than silently
    /// rolling over into a different valid timestamp.
    static func parseEnvelopeDate(_ dateString: String) -> Date? {
        // Strip trailing parenthetical comments such as " (UTC)"
        let cleaned = dateString.replacingOccurrences(
            of: "\\s*\\([^)]+\\)\\s*$",
            with: "",
            options: .regularExpression
        )

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z", // RFC 5322
            "EEE, d MMM yyyy HH:mm:ss Z", // single-digit day
            "d MMM yyyy HH:mm:ss Z", // no weekday
            "dd MMM yyyy HH:mm:ss Z", // no weekday, two-digit day
            "EEE, dd MMM yy HH:mm:ss Z", // two-digit year
            "EEE, dd MMM yyyy HH:mm:ss", // no timezone
            "EEE, d MMM yyyy HH:mm:ss",
            "d MMM yyyy HH:mm:ss", // no weekday, no timezone
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
        var searchRange = value.startIndex ..< value.endIndex
        while let openRange = value.range(of: "<", range: searchRange),
              let closeRange = value.range(of: ">", range: openRange.upperBound ..< value.endIndex) {
            let token = String(value[openRange.lowerBound ... closeRange.lowerBound])
            if let id = MessageID(token) {
                results.append(id)
            }
            searchRange = closeRange.upperBound ..< value.endIndex
        }
        return results
    }
}
