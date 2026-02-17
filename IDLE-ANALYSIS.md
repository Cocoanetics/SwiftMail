# IDLE Event Loss Analysis

## The Problem

IMAP servers can send untagged responses (EXISTS, EXPUNGE, FETCH, etc.) at **any time** — not just during IDLE. The current implementation has windows where these responses are silently lost.

## Architecture

The NIO pipeline uses **transient command handlers**: each command (IDLE, NOOP, etc.) adds a handler to the pipeline, and the handler **removes itself** when it receives its tagged OK response:

```
BaseIMAPCommandHandler.handleCompletion():
    isCompleted = true
    context.pipeline.removeHandler(self, promise: nil)  // ← handler gone
```

Responses always flow through the pipeline via `context.fireChannelRead(data)`, but if no handler exists to process them, they hit the pipeline tail and are **silently dropped**.

## The IDLE Cycle and Its Gaps

The cycling in `IMAPServer.idle(on:cycleInterval:)` works like this:

```
┌─────────────────────────────────────────────────────────┐
│ Cycle N                                                 │
│                                                         │
│  1. connection.idle()     → IdleHandler added to pipe   │
│  2. Events flow...        → IdleHandler yields them     │
│  3. Timer fires           → connection.done() sends     │
│                             DONE to server              │
│  4. Server sends tagged OK                              │
│  5. IdleHandler processes → removes itself from pipe    │
│     continuation.finish()                               │
│                                                         │
│  ══════ GAP A: NO HANDLER IN PIPELINE ══════            │
│                                                         │
│  6. connection.noop()     → NoopHandler added to pipe   │
│  7. Server responds       → NoopHandler collects events │
│  8. NoopHandler processes → removes itself from pipe    │
│                                                         │
│  ══════ GAP B: NO HANDLER IN PIPELINE ══════            │
│                                                         │
│  9. Back to step 1 (next cycle)                         │
└─────────────────────────────────────────────────────────┘
```

### Gap A: Between IdleHandler removal and NoopHandler addition

After the IdleHandler removes itself (step 5) and before `connection.noop()` adds the NoopHandler (step 6), there's an **async scheduling gap**. This includes:
- The task group collecting results
- The `gotBye` check
- The `Task.isCancelled` check
- The `connection.noop()` call setting up and adding the handler

Any untagged server push during this window is parsed by `IMAPClientHandler` but has no command handler to capture it → **lost**.

### Gap B: Between NoopHandler removal and next IdleHandler addition

Same pattern. After NOOP completes (step 8) and before the next `connection.idle()` adds a new IdleHandler (step 9), another async gap exists.

### How big are these gaps?

In wall-clock time: microseconds to low milliseconds (just Swift async task scheduling). But IMAP servers can send notifications at any instant, and high-traffic mailboxes (shared mailboxes, mailing lists) could hit these windows.

## Events Between DONE and Tagged OK

This is actually **fine**. The IdleHandler stays in the pipeline until it receives the tagged OK. Events arriving between the DONE command and the tagged OK are processed normally by the IdleHandler and yielded to the stream. The server is required to send any pending notifications before the tagged OK.

## The Real Fix: Persistent Buffer Handler

The proper solution is a **persistent untagged response handler** that lives in the pipeline for the lifetime of the connection, below the transient command handlers:

```
Pipeline (top to bottom):
  SSLHandler
  IMAPClientHandler (parser)
  [Transient command handler - comes and goes]
  UntaggedResponseBuffer (PERSISTENT - always there)
  IMAPLogger
```

### How it works:

1. `UntaggedResponseBuffer` sits in the pipeline permanently
2. Transient command handlers are added **above** it
3. When a command handler is active, it processes responses and calls `fireChannelRead` — the buffer sees them but knows a handler is active (or the handler consumes them via `processResponse` returning `true`)
4. When **no command handler** is active, untagged responses fall through to the buffer, which stores them
5. When the next command handler is added, it **drains the buffer first** before processing new responses

### Implementation sketch:

```swift
final class UntaggedResponseBuffer: ChannelInboundHandler {
    typealias InboundIn = Response
    typealias InboundOut = Response
    
    private var buffer: [Response] = []
    private var hasActiveHandler = false
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        
        if !hasActiveHandler {
            // No command handler active — buffer this response
            if isUntaggedOrFetch(response) {
                buffer.append(response)
            }
        }
        
        // Always forward
        context.fireChannelRead(data)
    }
    
    /// Called by IMAPConnection when adding a new command handler
    func drainBuffer() -> [Response] {
        defer { buffer.removeAll() }
        return buffer
    }
    
    func setActiveHandler(_ active: Bool) {
        hasActiveHandler = active
    }
}
```

Then in `IMAPConnection`, when starting idle or noop:
1. Set `bufferHandler.setActiveHandler(true)`
2. Drain any buffered responses and feed them to the new handler
3. On handler completion: `bufferHandler.setActiveHandler(false)`

## Alternative: Simpler Approach

If the persistent buffer handler is too invasive, a simpler improvement:

**Pre-IDLE NOOP**: Before starting each IDLE cycle, send a NOOP first to collect any responses that arrived during the gap. This doesn't eliminate the gap but reduces its impact — anything that arrived between the last NOOP and the new IDLE start would be caught.

```swift
// Current: idle → done → noop → idle → done → noop
// Better:  idle → done → noop → noop → idle → done → noop → noop
// Or just: idle → done → noop+idle (minimize gap by combining)
```

The best simple fix: **make the NOOP-to-IDLE transition as tight as possible** by keeping it in a single synchronous command queue operation, or by adding the IdleHandler to the pipeline *before* sending the NOOP, so it's already there to catch anything.

## Summary

| Issue | Severity | Fix |
|-------|----------|-----|
| Gap between IdleHandler removal and NoopHandler | Medium | Persistent buffer handler |
| Gap between NoopHandler removal and next IdleHandler | Medium | Persistent buffer handler |
| Events between DONE and tagged OK | None | Already handled correctly |
| Silent dropping of unhandled event types | Fixed | PR #84 (merged) |

The persistent `UntaggedResponseBuffer` handler is the proper fix. It eliminates both gaps and makes the system robust against any future command sequencing changes.
