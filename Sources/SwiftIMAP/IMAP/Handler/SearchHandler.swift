import Foundation
import NIO
import NIOIMAP

public final class SearchHandler: BaseIMAPCommandHandler<[MessageIdentifier]>, IMAPCommandHandler {
    public typealias ResultType = [MessageIdentifier]
    public typealias InboundIn = Response
    public typealias InboundOut = Never
    
    private var searchResults: [MessageIdentifier] = []
    
    override public func processResponse(_ response: Response) -> Bool {
        let handled = super.processResponse(response)
        
        if case .search(let identifiers) = response {
            searchResults.append(contentsOf: identifiers.map { MessageIdentifier($0.rawValue) })
        }
        
        return handled
    }
    
    override public func handleTaggedOKResponse(_ response: TaggedResponse) {
        succeedWithResult(searchResults)
    }
    
    override public func handleTaggedErrorResponse(_ response: TaggedResponse) {
        failWithError(IMAPError.searchFailed(String(describing: response.state)))
    }
}
