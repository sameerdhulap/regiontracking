//
//  ActivityService.swift
//  RegionMonitor
//
//  Logs the motion activity CoreMotion classifies — stationary, walking,
//  running, cycling, automotive — so a region event can be read against what
//  the device was doing at the time. An exit logged while `stationary` is far
//  more likely to be fix wobble than one logged while `automotive`.
//
//  Live updates only arrive while the app is running; CoreMotion never wakes
//  it. CoreMotion does keep about seven days of history, though, so before
//  each live update is logged the gap since the last logged activity is
//  filled from that history. Backfilled entries are stamped with the
//  activity's own start time, so they sort into place in the timeline, and
//  carry `source=history`.
//
//  The backfill runs on every live update, not just on launch or foreground:
//  a background wake-up delivers a live update too, and logging it without
//  filling the gap first would move the cursor past history never recorded.
//

import CoreMotion
import Foundation

final class ActivityService {

    static let shared = ActivityService()

    /// How far back CoreMotion keeps activity history.
    private static let historyWindow: TimeInterval = 7 * 24 * 60 * 60

    private let manager = CMMotionActivityManager()

    /// Serial. Everything below `isRunning` is only touched from here.
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "RegionMonitor.Activity"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    /// Main thread only.
    private var isRunning = false

    /// Last activity logged, so an update that repeats it is dropped rather
    /// than filling the log.
    private var last: (activity: String, confidence: String)?

    /// Timestamp of the newest activity entry in the log; backfill starts
    /// here. Read from the store once per process, then kept in memory, since
    /// a write still in flight would not show up in a fetch.
    private var cursor: Date?
    private var cursorLoaded = false

    /// Live updates waiting on a backfill. They are handled one at a time so
    /// a query in flight can't be overtaken by the update after it.
    private var pending: [CMMotionActivity] = []
    private var isBackfilling = false

    private init() {}

    /// Starts activity updates. Idempotent; call on the main thread. The first
    /// call triggers the Motion & Fitness permission prompt.
    func start() {
        guard !isRunning else { return }

        guard CMMotionActivityManager.isActivityAvailable() else {
            LogWriter.shared.log(.error, detail: "Motion activity unavailable on this device")
            return
        }

        let status = CMMotionActivityManager.authorizationStatus()
        guard status != .denied && status != .restricted else {
            LogWriter.shared.log(.error, detail: "Motion activity not authorized status=\(status.label)")
            return
        }

        isRunning = true
        manager.startActivityUpdates(to: queue) { [weak self] activity in
            guard let self, let activity else { return }
            self.pending.append(activity)
            self.drain()
        }
    }

    // MARK: - Backfill

    private func drain() {
        guard !isBackfilling, let live = pending.first else { return }
        isBackfilling = true
        loadCursor { [weak self] in self?.backfill(before: live) }
    }

    private func loadCursor(then next: @escaping () -> Void) {
        guard !cursorLoaded else { next(); return }
        LogWriter.shared.latestTimestamp(of: .activity) { [weak self] date in
            self?.queue.addOperation {
                guard let self else { return }
                self.cursor = date
                self.cursorLoaded = true
                next()
            }
        }
    }

    /// Logs history between the cursor and `live`, then `live` itself. With no
    /// cursor — a first run — there is nothing to fill, and a week of history
    /// from before the trial began would only be noise.
    private func backfill(before live: CMMotionActivity) {
        guard let cursor else { finish(live); return }

        let from = max(cursor, live.startDate.addingTimeInterval(-Self.historyWindow))
        guard from < live.startDate else { finish(live); return }

        manager.queryActivityStarting(from: from, to: live.startDate, to: queue) { [weak self] activities, error in
            guard let self else { return }
            if let error {
                LogWriter.shared.log(.error, detail: "Motion history query failed: \(error.localizedDescription)")
            }
            for activity in activities ?? [] where activity.startDate > from && activity.startDate < live.startDate {
                self.record(activity, backfilled: true)
            }
            self.finish(live)
        }
    }

    private func finish(_ live: CMMotionActivity) {
        record(live, backfilled: false)
        pending.removeFirst()
        isBackfilling = false
        drain()
    }

    // MARK: - Logging

    private func record(_ activity: CMMotionActivity, backfilled: Bool) {
        let current = (activity: activity.label, confidence: activity.confidence.label)
        if let last, last == current { return }

        let prev = last?.activity ?? "unknown"
        last = current

        if backfilled {
            cursor = activity.startDate
            LogWriter.shared.log(.activity,
                                 detail: "activity=\(current.activity) confidence=\(current.confidence) prev=\(prev) source=history",
                                 timestamp: activity.startDate)
        } else {
            cursor = Date()
            LogWriter.shared.log(.activity, detail: String(
                format: "activity=%@ confidence=%@ prev=%@ age=%.1fs",
                current.activity, current.confidence, prev, -activity.startDate.timeIntervalSinceNow
            ))
        }
    }
}

// MARK: - Readable labels

extension CMMotionActivity {
    /// Every flag that is set, joined with `+`. More than one can be true at
    /// once — `automotive+stationary` is a car stopped at a light.
    var label: String {
        let flags: [(Bool, String)] = [
            (stationary, "stationary"),
            (walking, "walking"),
            (running, "running"),
            (cycling, "cycling"),
            (automotive, "automotive")
        ]
        let set = flags.filter(\.0).map(\.1)
        return set.isEmpty ? "unknown" : set.joined(separator: "+")
    }
}

extension CMMotionActivityConfidence {
    var label: String {
        switch self {
        case .low:         return "low"
        case .medium:      return "medium"
        case .high:        return "high"
        @unknown default:  return "unknown"
        }
    }
}

extension CMAuthorizationStatus {
    var label: String {
        switch self {
        case .notDetermined:  return "notDetermined"
        case .restricted:     return "restricted"
        case .denied:         return "denied"
        case .authorized:     return "authorized"
        @unknown default:     return "unknown"
        }
    }
}
