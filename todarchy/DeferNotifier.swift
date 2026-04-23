import Foundation
import UserNotifications
#if canImport(AppKit)
import AppKit
#endif

/// Watches the store for `deferUntil` timestamps that have elapsed and fires
/// a local notification for each one. De-dup state is persisted next to
/// tasks.json as `notified.json` so the same task doesn't notify twice.
@MainActor
final class DeferNotifier {
    static let shared = DeferNotifier()

    private var timer: Timer?
    private var notifiedIds: Set<String>
    private let stateURL: URL
    private weak var store: TaskStore?

    /// Injected in tests so they don't hit UNUserNotificationCenter.
    var onFire: (TaskItem) -> Void

    init(stateURL: URL = DeferNotifier.defaultStateURL(),
         onFire: @escaping (TaskItem) -> Void = DeferNotifier.defaultFire) {
        self.stateURL = stateURL
        self.onFire = onFire
        if let data = try? Data(contentsOf: stateURL),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            self.notifiedIds = Set(ids)
        } else {
            self.notifiedIds = []
        }
    }

    static func defaultFire(_ task: TaskItem) {
        let content = UNMutableNotificationContent()
        content.title = "back on your list"
        content.body = task.title
        let req = UNNotificationRequest(
            identifier: "todarchy.defer.\(task.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    nonisolated static func defaultStateURL() -> URL {
        TaskStorePersistence.defaultFileURL()
            .deletingLastPathComponent()
            .appendingPathComponent("notified.json")
    }

    func attach(store: TaskStore) {
        self.store = store
    }

    /// Ask the user for permission and start the 60s scan loop.
    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Exposed for testing. Returns the tasks newly surfaced this tick.
    @discardableResult
    func tick(now: Date = Date()) -> [TaskItem] {
        guard let store else { return [] }
        let surfaced = store.tasks.filter { task in
            guard !task.isDone else { return false }
            guard let d = task.deferUntil else { return false }
            return d <= now && !notifiedIds.contains(task.id)
        }
        for task in surfaced {
            onFire(task)
            notifiedIds.insert(task.id)
        }
        if !surfaced.isEmpty {
            persist()
        }
        // Clean up state: drop ids whose tasks have been deleted.
        let existing = Set(store.tasks.map(\.id))
        let stale = notifiedIds.subtracting(existing)
        if !stale.isEmpty {
            notifiedIds.subtract(stale)
            persist()
        }
        return surfaced
    }

    private func persist() {
        let arr = Array(notifiedIds)
        if let data = try? JSONEncoder().encode(arr) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    /// Test hook: read current notified-ids set.
    var notifiedCount: Int { notifiedIds.count }
}
