@MainActor
protocol AudioProcessMonitoring: AnyObject {
    var activeApps: [AudioApp] { get }
    var onAppsChanged: (([AudioApp]) -> Void)? { get set }

    func start()
    func stop()

    /// Returns whether this app is currently producing output audio.
    /// The real implementation is derived from Core Audio process objects;
    /// test monitors can override it without manufacturing HAL objects.
    func isStreaming(_ app: AudioApp) -> Bool
}

extension AudioProcessMonitoring {
    func isStreaming(_ app: AudioApp) -> Bool {
        app.processObjectIDs.contains { $0.readProcessIsRunning() }
    }
}
