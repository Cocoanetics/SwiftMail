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
    public let sortCriteria: [SortCriteria]?
    
    public var handlerType: HandlerType.Type { SearchHandler<T>.self }
    
    public var timeoutSeconds: Int { return 10 }
    
    public init(identifierSet: MessageIdentifierSet<T>? = nil, criteria: [SearchCriteria], sortCriteria: [SortCriteria]? = nil) {
        self.identifierSet = identifierSet
        self.criteria = criteria
        self.sortCriteria = sortCriteria
    }
    
    public func validate() throws {
        guard !criteria.isEmpty else {
            throw IMAPError.invalidArgument("Search criteria cannot be empty")
        }
    }
    
    public func toTaggedCommand(tag: String) -> TaggedCommand {
        let nioCriteria = criteria.map { $0.toNIO() }
        
        if let sortCriteria = sortCriteria, !sortCriteria.isEmpty {
            let nioSortCriteria = sortCriteria.map { $0.toNIO() }
            if T.self == UID.self {
                return TaggedCommand(tag: tag, command: .uidSort(sort: nioSortCriteria, charset: "UTF-8", searchKey: .and(nioCriteria)))
            } else {
                return TaggedCommand(tag: tag, command: .sort(sort: nioSortCriteria, charset: "UTF-8", searchKey: .and(nioCriteria)))
            }
        } else {
            if T.self == UID.self {
                return TaggedCommand(tag: tag, command: .uidSearch(key: .and(nioCriteria)))
            } else {
                return TaggedCommand(tag: tag, command: .search(key: .and(nioCriteria)))
            }
        }
    }
}
