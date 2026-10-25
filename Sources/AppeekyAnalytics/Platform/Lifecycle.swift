#if canImport(UIKit) && os(iOS)
import UIKit

/// Forwards UIApplication foreground / background notifications to the client.
final class LifecycleObserver {
    private var tokens: [NSObjectProtocol] = []

    init(onForeground: @escaping @Sendable () -> Void, onBackground: @escaping @Sendable () -> Void) {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            onForeground()
        })
        tokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            onBackground()
        })
    }

    func stop() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
    }

    deinit { stop() }
}

/// Keeps the app running briefly after it goes to the background so the last
/// batch can be sent.
@MainActor
final class BackgroundTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    static func begin() -> BackgroundTask {
        let task = BackgroundTask()
        task.identifier = UIApplication.shared.beginBackgroundTask(withName: "AppeekyAnalytics.flush") { [weak task] in
            task?.end()
        }
        return task
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// True when the process was launched in the background (background fetch,
/// silent push, location…). Only known on the main thread.
func isLaunchedInBackground() -> Bool {
    guard Thread.isMainThread else { return false }
    return MainActor.assumeIsolated { UIApplication.shared.applicationState == .background }
}
#endif
