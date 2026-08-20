//
//  RegionMonitorApp.swift
//  RegionMonitor
//

import SwiftUI

@main
struct RegionMonitorApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.managedObjectContext, CoreDataStack.shared.viewContext)
                .environmentObject(LocationService.shared)
        }
    }
}
