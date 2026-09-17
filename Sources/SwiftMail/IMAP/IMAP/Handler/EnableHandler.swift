import NIOIMAPCore

final class EnableHandler: BaseIMAPCommandHandler<[Capability]>, IMAPCommandHandler, @unchecked Sendable {
    private var enabledCapabilities: [Capability] = []
    private var seenCapabilities: Set<Capability> = []

    override func handleTaggedOKResponse(_ response: TaggedResponse) {
        super.handleTaggedOKResponse(response)
        succeedWithResult(lock.withLock { enabledCapabilities })
    }

    override func handleUntaggedResponse(_ response: Response) -> Bool {
        if case .untagged(.enableData(let capabilities)) = response {
            lock.withLock {
                for capability in capabilities where seenCapabilities.insert(capability).inserted {
                    enabledCapabilities.append(capability)
                }
            }
            return false
        }
        return super.handleUntaggedResponse(response)
    }
}
