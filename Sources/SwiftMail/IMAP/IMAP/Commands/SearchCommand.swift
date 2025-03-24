import Foundation
import NIO
import NIOIMAP
import NIOIMAPCore

struct SearchCommand<T: MessageIdentifier>: IMAPCommand {
    // Update the result type to return a MessageIdentifierSet
    typealias ResultType = MessageIdentifierSet<T>
    typealias HandlerType = SearchHandler<T>
    
    let identifierSet: MessageIdentifierSet<T>?
    let criteria: [SearchCriteria]
    
    var timeoutSeconds: Int { return 10 }
    
    init(identifierSet: MessageIdentifierSet<T>? = nil, criteria: [SearchCriteria]) {
        self.identifierSet = identifierSet
        self.criteria = criteria
    }
    
    func validate() throws {
        guard !criteria.isEmpty else {
            throw IMAPError.invalidArgument("Search criteria cannot be empty")
        }
    }
    
    func toTaggedCommand(tag: String) -> TaggedCommand {
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
