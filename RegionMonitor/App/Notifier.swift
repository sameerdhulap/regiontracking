//
//  Notifier.swift
//  RegionMonitor
//
//  Local notifications for region crossings, so a crossing is visible in the
//  field without unlocking the phone and opening the Log tab. The log stays
//  the record of truth — a notification is just the thing that tells you to go
//  and look, and that the app is still alive out there.
//
//  Only genuine crossings notify. A crossing suppressed by the region's
//  entry/exit flags is logged as `region.state` rather than enter or exit, and
//  so never reaches here.
//

import Foundation
import UIKit
import UserNotifications

final class Notifier: NSObject {

    static let shared = Notifier()

    private let center = UNUserNotificationCenter.current()

    private override init() { super.init() }

    /// Called from `didFinishLaunching`. Without a delegate iOS silently
    /// swallows a notification while the app is frontmost, which for a
    /// field-test tool reads as a missed crossing rather than a hidden banner.
    ///
    /// The prompt is driven off `didBecomeActiveNotification` rather than
    /// `applicationDidBecomeActive`: this is a scene-based SwiftUI app, so the
    /// UIApplicationDelegate lifecycle callbacks are never invoked. Same reason
    /// AppStateTracker observes notifications.
    func start() {
        center.delegate = self

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.requestAuthorizationIfNeeded()
        }
    }

    /// Prompts only the first time. Driven from "app became active": a request
    /// made during a background relaunch cannot show its prompt, and would burn
    /// the one chance iOS gives you to ask.
    private func requestAuthorizationIfNeeded() {
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .notDetermined else { return }

            self?.center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    LogWriter.shared.log(.error, detail: "Notification authorization failed: \(error.localizedDescription)")
                } else {
                    LogWriter.shared.log(.note, detail: "Notification authorization \(granted ? "granted" : "denied")")
                }
            }
        }
    }

    /// Posts a crossing. `body` carries the distance and accuracy behind the
    /// event, because "entered X" on its own doesn't tell you whether to trust
    /// it — a margin inside the accuracy figure is the tell for a false
    /// crossing, and that is the whole question this app exists to answer.
    func postCrossing(_ type: EventType, region: String, body: String) {
        let content = UNMutableNotificationContent()

        switch type {
        case .regionEnter: content.title = "Entered \(region)"
        case .regionExit:  content.title = "Left \(region)"
        default:           return
        }

        content.body = body
        content.sound = .default
        content.threadIdentifier = region   // groups a flapping region into one stack

        // nil trigger delivers immediately, background relaunch included.
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)

        center.add(request) { error in
            guard let error else { return }
            LogWriter.shared.log(.error,
                                 regionIdentifier: region,
                                 detail: "Notification failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension Notifier: UNUserNotificationCenterDelegate {

    /// Show crossings even with the app frontmost. Testing this thing usually
    /// means watching the screen while walking, and a banner you only get when
    /// backgrounded is a banner you can't check against the log.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
