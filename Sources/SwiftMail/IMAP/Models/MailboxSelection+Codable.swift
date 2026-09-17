import Foundation
import NIOIMAPCore

extension Mailbox.Selection {
    private enum CodingKeys: String, CodingKey {
        case messageCount
        case recentCount
        case firstUnseen
        case uidValidity
        case uidNext
        case isReadOnly
        case availableFlags
        case permanentFlags
        case highestModSequence
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(messageCount, forKey: .messageCount)
        try container.encode(recentCount, forKey: .recentCount)
        try container.encode(firstUnseen, forKey: .firstUnseen)
        try container.encode(uidValidity, forKey: .uidValidity)
        try container.encode(uidNext, forKey: .uidNext)
        try container.encode(isReadOnly, forKey: .isReadOnly)
        try container.encode(availableFlags, forKey: .availableFlags)
        try container.encode(permanentFlags, forKey: .permanentFlags)
        if let highestModSequence {
            try container.encode(UInt64(highestModSequence), forKey: .highestModSequence)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageCount = try container.decode(Int.self, forKey: .messageCount)
        recentCount = try container.decode(Int.self, forKey: .recentCount)
        firstUnseen = try container.decode(Int.self, forKey: .firstUnseen)
        uidValidity = try container.decode(UIDValidity.self, forKey: .uidValidity)
        uidNext = try container.decode(UID.self, forKey: .uidNext)
        isReadOnly = try container.decode(Bool.self, forKey: .isReadOnly)
        availableFlags = try container.decode([Flag].self, forKey: .availableFlags)
        permanentFlags = try container.decode([Flag].self, forKey: .permanentFlags)

        guard let rawValue = try container.decodeIfPresent(UInt64.self, forKey: .highestModSequence) else {
            highestModSequence = nil
            return
        }
        guard let value = ModificationSequenceValue(exactly: rawValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: .highestModSequence,
                in: container,
                debugDescription: "Modification sequence must fit in the protocol's 63-bit range"
            )
        }
        highestModSequence = value
    }
}
