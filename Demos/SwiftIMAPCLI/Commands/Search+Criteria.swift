import ArgumentParser
import Foundation
import SwiftMail

extension Search {
    func buildCriteria() throws -> [SearchCriteria] {
        var criterias: [SearchCriteria] = []
        criterias.append(contentsOf: textCriteria())
        try criterias.append(contentsOf: headerCriteria())
        try criterias.append(contentsOf: dateCriteria())
        criterias.append(contentsOf: sizeCriteria())
        criterias.append(contentsOf: flagCriteria())

        if criterias.isEmpty {
            throw ValidationError("No search criteria provided. Use --subject, --from, --text, etc.")
        }

        if any, criterias.count > 1 {
            return [criterias.reduce(criterias[0]) { .or($0, $1) }]
        }

        return criterias
    }

    func attachmentExtensions() -> Set<String> {
        Set(
            attachment
                .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
        )
    }

    func buildSortCriteria() throws -> [SortCriterion] {
        try sort.map { rawValue in
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ValidationError("Empty --sort value is not allowed.")
            }

            let descending = trimmed.hasPrefix("-")
            let normalized = (descending ? String(trimmed.dropFirst()) : trimmed).lowercased()
            let key = try Self.sortKey(forNormalized: normalized, rawValue: rawValue)
            return descending ? .descending(key) : .ascending(key)
        }
    }

    // MARK: - Criterion groups

    private func textCriteria() -> [SearchCriteria] {
        var result: [SearchCriteria] = []
        appendOr(from.map { .from($0) }, into: &result)
        appendOr(subject.map { .subject($0) }, into: &result)
        appendOr(text.map { .text($0) }, into: &result)
        appendOr(body.map { .body($0) }, into: &result)
        appendOr(to.map { .to($0) }, into: &result)
        appendOr(cc.map { .cc($0) }, into: &result)
        appendOr(bcc.map { .bcc($0) }, into: &result)
        return result
    }

    private func headerCriteria() throws -> [SearchCriteria] {
        var parsed: [SearchCriteria] = []
        for headerValue in header {
            let parts = headerValue.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw ValidationError("Invalid header format: \(headerValue). Expected FIELD:VALUE.")
            }
            parsed.append(.header(parts[0], parts[1]))
        }
        var result: [SearchCriteria] = []
        appendOr(parsed, into: &result)
        return result
    }

    private func dateCriteria() throws -> [SearchCriteria] {
        var result: [SearchCriteria] = []
        if let since {
            try result.append(.since(Self.parseDate(since, label: "--since")))
        }
        if let before {
            try result.append(.before(Self.parseDate(before, label: "--before")))
        }
        if let on {
            try result.append(.on(Self.parseDate(on, label: "--on")))
        }
        if let sentSince {
            try result.append(.sentSince(Self.parseDate(sentSince, label: "--sent-since")))
        }
        if let sentBefore {
            try result.append(.sentBefore(Self.parseDate(sentBefore, label: "--sent-before")))
        }
        if let sentOn {
            try result.append(.sentOn(Self.parseDate(sentOn, label: "--sent-on")))
        }
        return result
    }

    private func sizeCriteria() -> [SearchCriteria] {
        var result: [SearchCriteria] = []
        if let larger {
            result.append(.larger(larger))
        }
        if let smaller {
            result.append(.smaller(smaller))
        }
        return result
    }

    private func flagCriteria() -> [SearchCriteria] {
        let mapping: [(Bool, SearchCriteria)] = [
            (seen, .seen),
            (unseen, .unseen),
            (flagged, .flagged),
            (unflagged, .unflagged),
            (answered, .answered),
            (unanswered, .unanswered),
            (deleted, .deleted),
            (undeleted, .undeleted),
            (draft, .draft),
            (undraft, .undraft),
            (recent, .recent),
            (new, .new),
            (old, .old)
        ]
        return mapping.compactMap { $0.0 ? $0.1 : nil }
    }

    // MARK: - Helpers

    private func appendOr(_ items: [SearchCriteria], into criterias: inout [SearchCriteria]) {
        guard let first = items.first else { return }
        let grouped = items.dropFirst().reduce(first) { .or($0, $1) }
        criterias.append(grouped)
    }

    private static func parseDate(_ value: String, label: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let date = formatter.date(from: value) else {
            throw ValidationError("Invalid \(label) date: \(value). Expected YYYY-MM-DD.")
        }
        return date
    }

    private static func sortKey(forNormalized normalized: String, rawValue: String) throws -> SortCriterion.Key {
        switch normalized {
            case "arrival":
                return .arrival
            case "cc":
                return .cc
            case "date":
                return .date
            case "from":
                return .from
            case "size":
                return .size
            case "subject":
                return .subject
            case "to":
                return .to
            case "displayfrom", "display-from":
                return .displayFrom
            case "displayto", "display-to":
                return .displayTo
            default:
                throw ValidationError(
                    "Unsupported --sort value: \(rawValue). "
                        + "Supported values: arrival, cc, date, from, size, subject, to, "
                        + "displayfrom, displayto. Prefix with '-' for descending."
                )
        }
    }
}
