//
//  ActivityService.swift
//  RegionMonitor
//
//  Tracks the motion activity CoreMotion classifies — stationary, walking,
//  running, cycling, automotive — so location and region entries can say what
//  the device was doing at the time. An exit logged while `stationary` is far
//  more likely to be fix wobble than one logged while `automotive`.
//
//  Activity has no log entries of its own; it only annotates other events
//  through `currentFields`. Updates only arrive while the app is running, and
//  CoreMotion never wakes it, so after a relaunch entries read
//  `activity=unknown` until the first update lands.
//

import CoreMotion
import Foundation

final class ActivityService {

    static let shared = ActivityService()

    private let manager = CMMotionActivityManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "RegionMonitor.Activity"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    /// Main thread only.
    private var isRunning = false

    private let lock = NSLock()
    private var current: CMMotionActivity?

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
            self.lock.lock()
            self.current = activity
            self.lock.unlock()
        }
    }

    /// The latest activity as log fields, for annotating other entries:
    /// `activity=walking activityConfidence=high`, or `activity=unknown`
    /// before the first update or when motion access is unavailable.
    /// Safe from any thread.
    var currentFields: String {
        lock.lock()
        let activity = current
        lock.unlock()
        guard let activity else { return "activity=unknown" }
        return "activity=\(activity.label) activityConfidence=\(activity.confidence.label)"
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
