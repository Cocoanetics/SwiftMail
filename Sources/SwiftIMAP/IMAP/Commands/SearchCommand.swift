import Foundation
import NIO
import NIOIMAP

public struct SearchCommand<T: MessageIdentifier>: IMAPCommand {
    public typealias ResultType = [T]
    public typealias HandlerType = SearchHandler
    
    public let identifierSet: MessageIdentifierSet<T>?
    public let criteria: [SearchCriteria]
    
    public var handlerType: HandlerType.Type { SearchHandler.self }
    
    public var timeoutSeconds: Int { return 10 }
    
    public init(identifierSet: MessageIdentifierSet<T>? = nil, criteria: [SearchCriteria]) {
        self.identifierSet = identifierSet
        self.criteria = criteria
    }
    
    public func validate() throws {
        guard !criteria.isEmpty else {
            throw IMAPError.invalidArgument("Search criteria cannot be empty")
        }
    }
    
    public func toTaggedCommand(tag: String) -> TaggedCommand {
        let nioCriteria = criteria.map { $0.toNIO() }
        
        if T.self == UID.self {
            return TaggedCommand(tag: tag, command: .uidSearch(identifierSet?.toNIOSet() ?? .all, nioCriteria))
        } else {
            return TaggedCommand(tag: tag, command: .search(identifierSet?.toNIOSet() ?? .all, nioCriteria))
        }
    }
}
