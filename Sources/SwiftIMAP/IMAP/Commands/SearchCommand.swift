import Foundation
import NIO
import NIOIMAP
import NIOIMAPCore

public struct SearchCommand<T: MessageIdentifier>: IMAPCommand {
    // Update the result type to return a MessageIdentifierSet
    public typealias ResultType = MessageIdentifierSet<T>
    public typealias HandlerType = SearchHandler<T>
    
    public let identifierSet: MessageIdentifierSet<T>?
    public let criteria: [SearchCriteria]
    
    public var handlerType: HandlerType.Type { SearchHandler<T>.self }
    
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
            // For UID search, we need to use the key parameter
            return TaggedCommand(tag: tag, command: .uidSearch(key: .and(nioCriteria)))
        } else {
            // For regular search, we need to use the key parameter
            return TaggedCommand(tag: tag, command: .search(key: .and(nioCriteria)))
        }
    }
}
