import Foundation


enum HostTaskLiveUpdate: Sendable {
    case snapshot(HostTaskView)
    case presentation(HostPresentationEvent)
}

struct HostTaskLiveSession: Sendable {
    let client: FlowerollHostClient
    let taskID: String
    let initialSnapshot: HostTaskView?

    init(
        client: FlowerollHostClient,
        taskID: String,
        initialSnapshot: HostTaskView? = nil
    ) {
        self.client = client
        self.taskID = taskID
        self.initialSnapshot = initialSnapshot
    }

    /// Rebuild from durable Host state first, then follow PresentationEvent
    /// deltas. Network/SSE loss never becomes Task truth: reconnect resumes
    /// from the last durable seq, and important/user-required boundaries refresh
    /// a coherent `/view` snapshot so pending interaction state stays current.
    func updates() -> AsyncThrowingStream<HostTaskLiveUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var cursor = 0
                var reconnectDelay: UInt64 = 250_000_000
                let maxReconnectDelay: UInt64 = 4_000_000_000

                do {
                    let viewSeed = initialSnapshot
                    var view: HostTaskView
                    if let viewSeed {
                        // The caller has just completed the authoritative,
                        // coalesced `/view` read. Reuse it as the live-session
                        // cursor instead of issuing the same GET again during
                        // a Task Detail -> Home ownership handoff.
                        view = viewSeed
                    } else {
                        view = try await client.fetchTaskView(taskID: taskID)
                    }
                    cursor = view.presentationCursor
                    continuation.yield(.snapshot(view))
                    if Self.isTerminal(view.task.status) {
                        continuation.finish()
                        return
                    }

                    while !Task.isCancelled {
                        do {
                            var receivedAny = false
                            for try await event in client.presentationEvents(
                                taskID: taskID,
                                afterSeq: cursor
                            ) {
                                try Task.checkCancellation()
                                guard event.seq > cursor else { continue }
                                cursor = event.seq
                                receivedAny = true
                                continuation.yield(.presentation(event))

                                if event.attentionLevel == "USER_REQUIRED"
                                    || event.attentionLevel == "IMPORTANT"
                                    || event.payload.kind.uppercased() == "TOOL_ACTIVITY"
                                {
                                    view = try await client.fetchTaskView(taskID: taskID)
                                    cursor = max(cursor, view.presentationCursor)
                                    continuation.yield(.snapshot(view))
                                    if Self.isTerminal(view.task.status) {
                                        continuation.finish()
                                        return
                                    }
                                }
                            }

                            // Server closes terminal streams after replay, but an
                            // ordinary connection may also end. Refresh durable
                            // state before deciding whether to stop or reconnect.
                            view = try await client.fetchTaskView(taskID: taskID)
                            cursor = max(cursor, view.presentationCursor)
                            continuation.yield(.snapshot(view))
                            if Self.isTerminal(view.task.status) {
                                continuation.finish()
                                return
                            }
                            reconnectDelay = receivedAny ? 250_000_000 : min(
                                reconnectDelay * 2,
                                maxReconnectDelay
                            )
                        } catch is CancellationError {
                            continuation.finish()
                            return
                        } catch let problem as HostProblem {
                            // Authentication, stale endpoint and semantic HTTP
                            // failures are not transient connectivity issues.
                            continuation.finish(throwing: problem)
                            return
                        } catch let security as HostClientSecurityError {
                            continuation.finish(throwing: security)
                            return
                        } catch {
                            // Keep the last acknowledged cursor. A later
                            // connection replays every durable event after it.
                            reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
                        }

                        try await Task.sleep(nanoseconds: reconnectDelay)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func isTerminal(_ status: String) -> Bool {
        switch status.lowercased() {
        case "completed", "failed", "cancelled":
            return true
        default:
            return false
        }
    }
}
