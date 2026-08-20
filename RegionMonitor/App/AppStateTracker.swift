//
//  AppStateTracker.swift
//  RegionMonitor
//
//  UIApplication.applicationState and UIDevice.batteryLevel are main-thread
//  only, but location callbacks can land on a background queue. This caches
//  both so the log writer can read them from anywhere without a main-thread
//  hop (which would also let the values drift).
//

import UIKit

final class AppStateTracker {

    static let shared = AppStateTracker()

    private let lock = NSLock()
    private var _state = "unknown"
    private var _battery: Float = -1

    var state: String {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    var batteryLevel: Float {
        lock.lock(); defer { lock.unlock() }
        return _battery
    }

    private init() {}

    /// Call once from `didFinishLaunchingWithOptions`, on the main thread.
    func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refresh()

        let names: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willEnterForegroundNotification,
            UIDevice.batteryLevelDidChangeNotification
        ]

        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
        }
    }

    private func refresh() {
        let stateString: String
        switch UIApplication.shared.applicationState {
        case .active:      stateString = "foreground"
        case .inactive:    stateString = "inactive"
        case .background:  stateString = "background"
        @unknown default:  stateString = "unknown"
        }

        let level = UIDevice.current.batteryLevel

        lock.lock()
        _state = stateString
        _battery = level
        lock.unlock()
    }
}
