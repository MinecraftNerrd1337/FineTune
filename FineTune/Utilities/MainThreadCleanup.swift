import Foundation

/// Runs teardown work on the main thread from a plain (nonisolated) `deinit`.
///
/// This replaces `isolated deinit` (SE-0371), whose runtime support only ships with
/// macOS 15.4. Behavior matches it: the work runs inline when the last release happens
/// on the main thread, otherwise it is queued to the main queue.
///
/// Rules for callers:
/// - Copy everything the work needs out of `self` *before* calling; a deinit cannot
///   keep `self` alive for deferred work.
/// - The captured values must not be touched from anywhere else afterwards. This holds
///   for the monitors, observer tokens and panels handed over by the deinits, which are
///   owned exclusively by the object being destroyed.
enum MainThreadCleanup {
    private struct UncheckedWork: @unchecked Sendable {
        let run: () -> Void
    }

    static func run(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            let box = UncheckedWork(run: work)
            DispatchQueue.main.async { box.run() }
        }
    }
}
