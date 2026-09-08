//
//  AppDelegate.swift
//  RegionMonitor
//
//  Everything location-related has to be wired up synchronously here. When
//  iOS relaunches a terminated app for a region crossing, it calls this
//  method and then delivers the queued event — anything deferred to a later
//  runloop tick misses it.
//

import CoreLocation
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {

        AppStateTracker.shared.start()

        // Before anything can post: a notification raised during this launch
        // needs the delegate already in place to show while frontmost.
        Notifier.shared.start()

        // Touch the stack now so the store is open before the first callback.
        _ = CoreDataStack.shared

        let relaunchedForLocation = launchOptions?[.location] != nil

        LogWriter.shared.log(
            relaunchedForLocation ? .appRelaunchByOS : .appLaunch,
            detail: "state=\(AppStateTracker.shared.state) backgroundMode=\(LocationService.hasLocationBackgroundMode)"
        )

        LocationService.shared.bootstrap()

        // Open the CLMonitor now, whatever the authorization state.
        // CoreLocation stops monitoring a condition when an event is pending
        // for it and no monitor has been opened to receive it, so this is the
        // CLMonitor-era equivalent of wiring up the delegate synchronously.
        LocationService.shared.startEngine()

        // Re-arm monitoring on every launch. Conditions do persist across
        // termination — CoreLocation stores them itself — but they're lost on
        // reinstall, so reconciling here is cheap and removes a whole class of
        // "it stopped working after a few days" reports.
        let status = LocationService.shared.authorizationStatus
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            LocationService.shared.startMonitoringAll()
        }

        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        LogWriter.shared.log(.appState, detail: "entered background")
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        LogWriter.shared.log(.appState, detail: "entering foreground")
        LocationService.shared.syncRegions()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        LogWriter.shared.log(.appState, detail: "willTerminate")
    }
}
