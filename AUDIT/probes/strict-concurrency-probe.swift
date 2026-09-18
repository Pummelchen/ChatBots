// Deliberate violation for the audit's language-standard proof (AUDIT/probes):
// a non-Sendable value captured across a Task/actor boundary.
// Swift 6 language mode with complete strict concurrency must reject it.
final class NotSendable {
    var value = 0
}

@MainActor
func onMain(_ item: NotSendable) {}

func probe() {
    let item = NotSendable()
    Task.detached {
        await onMain(item)
    }
}
