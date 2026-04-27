import Foundation
@preconcurrency import NIOIMAP
import NIOIMAPCore

enum LocalSortFallback {
    static func isSortResponseDecodeFailure(_ error: Error) -> Bool {
        guard let decoderError = error as? IMAPDecoderError else {
            return false
        }

        var buffer = decoderError.buffer
        let prefixLength = min(buffer.readableBytes, 32)
        guard let prefix = buffer.readString(length: prefixLength) else {
            return false
        }

        return prefix.hasPrefix("* SORT\r\n") || prefix.hasPrefix("* SORT ")
    }

    static func makeExtendedSearchResult<T: MessageIdentifier>(
        from infos: [MessageInfo],
        as identifierType: T.Type,
        sortCriteria: [SortCriterion],
        partialRange: PartialRange? = nil
    ) throws -> ExtendedSearchResult<T> {
        if sortCriteria.contains(where: { criterion in
            if case let .ascending(key) = criterion, key == .size {
                return true
            }
            if case let .descending(key) = criterion, key == .size {
                return true
            }
            return false
        }) {
            throw IMAPError.commandFailed("Local SORT fallback does not support SIZE sort criteria")
        }

        let sortable = try infos.enumerated().map { index, info in
            let identifier = try identifier(from: info, as: identifierType)
            return SortableMessage(identifier: identifier, info: info, originalIndex: index)
        }

        let ordered = sortable.sorted { lhs, rhs in
            for criterion in sortCriteria {
                let result = compare(lhs.info, rhs.info, criterion: criterion)
                if result != .orderedSame {
                    switch criterion {
                    case .ascending:
                        return result == .orderedAscending
                    case .descending:
                        return result == .orderedDescending
                    }
                }
            }

            return lhs.originalIndex < rhs.originalIndex
        }.map(\.identifier)

        let all = MessageIdentifierSet<T>(ordered)
        let partial = partialRange.map { range in
            let slice = apply(range, to: ordered)
            return ExtendedSearchResult<T>.PartialResult(range: range, results: MessageIdentifierSet<T>(slice))
        }

        return ExtendedSearchResult(
            count: ordered.count,
            min: ordered.min(),
            max: ordered.max(),
            all: partial == nil ? (all.isEmpty ? nil : all) : nil,
            ordered: ordered,
            partial: partial
        )
    }

    private struct SortableMessage<T: MessageIdentifier> {
        let identifier: T
        let info: MessageInfo
        let originalIndex: Int
    }

    private static func identifier<T: MessageIdentifier>(from info: MessageInfo, as _: T.Type) throws -> T {
        if T.self == UID.self {
            guard let uid = info.uid else {
                throw IMAPError.commandFailed("Local SORT fallback requires UIDs for UID-based results")
            }
            return T(uid.value)
        }

        return T(info.sequenceNumber.value)
    }

    private static func compare(_ lhs: MessageInfo, _ rhs: MessageInfo, criterion: SortCriterion) -> ComparisonResult {
        let key: SortCriterion.Key

        switch criterion {
        case .ascending(let sortKey):
            key = sortKey
        case .descending(let sortKey):
            key = sortKey
        }

        return compare(lhs, rhs, key: key)
    }

    private static func compare(_ lhs: MessageInfo, _ rhs: MessageInfo, key: SortCriterion.Key) -> ComparisonResult {
        switch key {
        case .arrival:
            return compare(lhs.internalDate, rhs.internalDate)
        case .cc:
            return compareStrings(addressMailbox(lhs.cc.first), addressMailbox(rhs.cc.first))
        case .date:
            return compare(lhs.date ?? lhs.internalDate, rhs.date ?? rhs.internalDate)
        case .from:
            return compareStrings(addressMailbox(lhs.from), addressMailbox(rhs.from))
        case .size:
            return .orderedSame
        case .subject:
            return compareStrings(baseSubject(lhs.subject), baseSubject(rhs.subject))
        case .to:
            return compareStrings(addressMailbox(lhs.to.first), addressMailbox(rhs.to.first))
        case .displayFrom:
            return compareStrings(addressDisplay(lhs.from), addressDisplay(rhs.from))
        case .displayTo:
            return compareStrings(addressDisplay(lhs.to.first), addressDisplay(rhs.to.first))
        }
    }

    private static func compare(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        let left = lhs ?? .distantPast
        let right = rhs ?? .distantPast

        if left < right {
            return .orderedAscending
        } else if left > right {
            return .orderedDescending
        } else {
            return .orderedSame
        }
    }

    private static func compareStrings(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.caseInsensitiveCompare(rhs)
    }

    private static func addressMailbox(_ rawValue: String?) -> String {
        let components = addressComponents(rawValue)
        return components.mailbox
    }

    private static func addressDisplay(_ rawValue: String?) -> String {
        let components = addressComponents(rawValue)
        return components.display
    }

    private static func addressComponents(_ rawValue: String?) -> (display: String, mailbox: String) {
        let value = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard
            let leftBracket = value.lastIndex(of: "<"),
            let rightBracket = value.lastIndex(of: ">"),
            leftBracket < rightBracket
        else {
            return (display: value.lowercased(), mailbox: value.lowercased())
        }

        let display = value[..<leftBracket]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .lowercased()
        let mailbox = value[value.index(after: leftBracket)..<rightBracket]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return (
            display: display.isEmpty ? mailbox : display,
            mailbox: mailbox
        )
    }

    private static func baseSubject(_ rawValue: String?) -> String {
        guard let rawValue else {
            return ""
        }

        var subject = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixPattern = "^(?:(?:re|fw|fwd):\\s*)+"

        while let range = subject.range(of: prefixPattern, options: [.regularExpression, .caseInsensitive]) {
            subject.removeSubrange(range)
            subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return subject.lowercased()
    }

    private static func apply<T>(_ range: PartialRange, to ordered: [T]) -> [T] {
        guard !ordered.isEmpty else {
            return []
        }

        switch range {
        case .first(let sequenceRange):
            let start = max(Int(sequenceRange.range.lowerBound.rawValue) - 1, 0)
            let end = min(Int(sequenceRange.range.upperBound.rawValue), ordered.count)
            guard start < end else {
                return []
            }
            return Array(ordered[start..<end])

        case .last(let sequenceRange):
            let lower = Int(sequenceRange.range.lowerBound.rawValue)
            let upper = Int(sequenceRange.range.upperBound.rawValue)
            let start = max(ordered.count - upper, 0)
            let end = min(max(ordered.count - lower + 1, 0), ordered.count)
            guard start < end else {
                return []
            }
            return Array(ordered[start..<end])
        }
    }
}
