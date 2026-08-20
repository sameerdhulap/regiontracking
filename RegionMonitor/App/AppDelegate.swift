//
//  AppDelegate.swift
//  RegionMonitor
//
//  Everything location-related has to be wired up synchronously here. When
//  iOS relaunches a terminated app for a region crossing, it calls this
//  method and then delivers the queued delegate callback — anything deferred
//  to a later runloop tick misses the event.
//

import CoreLocation
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {

        AppStateTracker.shared.start()

        // Touch the stack now so the store is open before the first callback.
        _ = CoreDataStack.shared

        let relaunchedForLocation = launchOptions?[.location] != nil

        LogWriter.shared.log(
            relaunchedForLocation ? .appRelaunchByOS : .appLaunch,
            detail: "state=\(AppStateTracker.shared.state) backgroundMode=\(LocationService.hasLocationBackgroundMode)"
        )

        LocationService.shared.bootstrap()

        // Re-arm monitoring on every launch. Regions do persist across
        // termination, but they're lost on reinstall and can be evicted, so
        // reconciling here is cheap and removes a whole class of "it stopped
        // working after a few days" reports.
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
