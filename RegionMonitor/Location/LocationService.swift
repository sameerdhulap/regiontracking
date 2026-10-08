//
//  LocationService.swift
//  RegionMonitor
//
//  Owns the single CLLocationManager for the process. It must be created and
//  have its delegate wired up *synchronously* inside
//  didFinishLaunchingWithOptions — if the app is relaunched into the
//  background for a location event and the delegate isn't set by the time
//  that method returns, the event is dropped.
//
//  Region monitoring is *not* here: it lives in RegionMonitorEngine on top of
//  CLMonitor. What's left on the manager is authorization, significant-change
//  and visit monitoring, and continuous/one-shot fixes.
//

import CoreLocation
import Foundation
import UIKit

final class LocationService: NSObject, ObservableObject {

    static let shared = LocationService()

    /// Self-imposed cap on simultaneously monitored conditions, carried over
    /// from the 20-region limit CLLocationManager enforced. CLMonitor doesn't
    /// document a number; `conditionLimitExceeded` on an event is how you find
    /// out you've passed whatever it is.
    static let maxMonitoredRegions = 20

    private let manager = CLLocationManager()

    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization = .reducedAccuracy
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var monitoredIdentifiers: Set<String> = []
    @Published var isStreamingContinuousUpdates = false

    /// Cached at bootstrap so the monitoring actor can clamp radii without
    /// touching CLLocationManager off the main thread.
    private(set) var maximumRegionRadius: CLLocationDistance = .greatestFiniteMagnitude

    private override init() {
        super.init()
    }

    // MARK: - Bootstrap

    func bootstrap() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false

        // Setting this without the `location` UIBackgroundMode throws an
        // exception at runtime, so check the bundle rather than trusting the
        // project settings.
        if Self.hasLocationBackgroundMode {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        } else {
            LogWriter.shared.log(.error, detail: "UIBackgroundModes is missing `location` — background updates disabled")
        }

        authorizationStatus = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        maximumRegionRadius = manager.maximumRegionMonitoringDistance
        LegacyRegionMonitor.shared.attach(to: manager)
        updateServiceSession(for: authorizationStatus)
    }

    /// iOS 18 wants a CLServiceSession outstanding while an app uses location.
    /// No-op below iOS 18, where the concept doesn't exist.
    private func updateServiceSession(for status: CLAuthorizationStatus) {
        if #available(iOS 18.0, *) {
            Task { @MainActor in ServiceSession.shared.update(for: status) }
        }
    }

    /// True when region monitoring runs on CLMonitor. iOS 16 has no such
    /// class, so it falls back to CLCircularRegion in LegacyRegionMonitor.
    /// This is the only place the choice is made.
    static var usesConditionMonitoring: Bool {
        if #available(iOS 17.0, *) { return true }
        return false
    }

    /// Opens the CLMonitor and starts draining its events. Called
    /// unconditionally at launch: CoreLocation drops a condition when an event
    /// is pending for it and nothing has opened the monitor to receive it.
    ///
    /// No-op on the legacy path — CLCircularRegion delivers through the
    /// delegate, which `bootstrap()` has already wired up.
    func startEngine() {
        if #available(iOS 17.0, *) {
            Task { await RegionMonitorEngine.shared.start() }
        }
    }

    static var hasLocationBackgroundMode: Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        return modes.contains("location")
    }

    // MARK: - Authorization

    func requestAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            // iOS only grants Always as an upgrade from When In Use, and only
            // once — after that the user has to go to Settings.
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Monitoring lifecycle

    /// Starts significant-change monitoring and reconciles the regions the OS
    /// is actually tracking against what's in the store. Safe to call on every
    /// launch — it's idempotent.
    func startMonitoringAll() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else {
            LogWriter.shared.log(.error, detail: "Significant location change monitoring unavailable")
            return
        }

        manager.startMonitoringSignificantLocationChanges()
        manager.startMonitoringVisits()

        syncRegions()
    }

    /// Reconciles the monitored conditions against Core Data. Conditions do
    /// survive app termination — CoreLocation persists them itself — but
    /// they're dropped on reinstall, so reconciling on launch is cheap
    /// insurance.
    func syncRegions() {
        if #available(iOS 17.0, *) {
            Task { await RegionMonitorEngine.shared.sync() }
        } else {
            LegacyRegionMonitor.shared.sync()
        }
    }

    func stopMonitoring(identifier: String) {
        if #available(iOS 17.0, *) {
            Task { await RegionMonitorEngine.shared.remove(identifier: identifier) }
        } else {
            LegacyRegionMonitor.shared.remove(identifier: identifier)
        }
    }

    /// Asks for the state of every monitored region.
    ///
    /// The two backends differ here, and the log says which you got. On iOS 16
    /// this is a real `requestState(for:)` — CoreLocation resolves the region
    /// now. On 17+ CLMonitor has no equivalent, so it replays the last
    /// persisted record, which may be hours old.
    func requestStateForAll() {
        if #available(iOS 17.0, *) {
            Task { await RegionMonitorEngine.shared.logCurrentStates() }
        } else {
            LegacyRegionMonitor.shared.requestStates()
        }
    }

    @MainActor
    func updateMonitoredIdentifiers(_ identifiers: Set<String>) {
        monitoredIdentifiers = identifiers
    }

    // MARK: - One-shot / continuous updates

    func requestOneShotLocation() {
        manager.requestLocation()
    }

    func setContinuousUpdates(_ on: Bool) {
        isStreamingContinuousUpdates = on
        if on {
            manager.startUpdatingLocation()
            LogWriter.shared.log(.note, detail: "Continuous updates ON")
        } else {
            manager.stopUpdatingLocation()
            LogWriter.shared.log(.note, detail: "Continuous updates OFF")
        }
    }

    var currentLocationForNewRegion: CLLocation? { lastLocation }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let accuracy = manager.accuracyAuthorization

        DispatchQueue.main.async {
            self.authorizationStatus = status
            self.accuracyAuthorization = accuracy
        }

        LogWriter.shared.log(.authChange,
                             detail: "status=\(status.label) accuracy=\(accuracy.label)")

        updateServiceSession(for: status)

        if status == .authorizedAlways || status == .authorizedWhenInUse {
            startMonitoringAll()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        DispatchQueue.main.async { self.lastLocation = latest }

        let activity = ActivityService.shared.currentFields
        for location in locations {
            LogWriter.shared.log(.location, location: location,
                                 detail: String(format: "age=%.1fs %@", -location.timestamp.timeIntervalSinceNow, activity))
        }
    }

    // MARK: Region callbacks — legacy backend only
    //
    // Inert on iOS 17+: nothing is registered with CLLocationManager there, so
    // these never fire. Guarded anyway so the intent is not left to inference.

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard !Self.usesConditionMonitoring else { return }
        LegacyRegionMonitor.shared.didEnter(region)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard !Self.usesConditionMonitoring else { return }
        LegacyRegionMonitor.shared.didExit(region)
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard !Self.usesConditionMonitoring else { return }
        LegacyRegionMonitor.shared.didDetermineState(state, for: region)
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        guard !Self.usesConditionMonitoring else { return }
        LegacyRegionMonitor.shared.monitoringDidFail(for: region, error: error)
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let location = CLLocation(coordinate: visit.coordinate,
                                  altitude: 0,
                                  horizontalAccuracy: visit.horizontalAccuracy,
                                  verticalAccuracy: -1,
                                  timestamp: visit.arrivalDate)
        let arrival = visit.arrivalDate == .distantPast ? "unknown" : ISO8601DateFormatter().string(from: visit.arrivalDate)
        let departure = visit.departureDate == .distantFuture ? "ongoing" : ISO8601DateFormatter().string(from: visit.departureDate)
        LogWriter.shared.log(.visit, location: location, detail: "arrival=\(arrival) departure=\(departure)")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient — CL will keep trying.
        if let clError = error as? CLError, clError.code == .locationUnknown { return }
        LogWriter.shared.log(.error, detail: error.localizedDescription)
    }
}

// MARK: - Readable labels

extension CLAuthorizationStatus {
    var label: String {
        switch self {
        case .notDetermined:       return "notDetermined"
        case .restricted:          return "restricted"
        case .denied:              return "denied"
        case .authorizedAlways:    return "always"
        case .authorizedWhenInUse: return "whenInUse"
        @unknown default:          return "unknown"
        }
    }
}

extension CLAccuracyAuthorization {
    var label: String {
        switch self {
        case .fullAccuracy:    return "full"
        case .reducedAccuracy: return "reduced"
        @unknown default:      return "unknown"
        }
    }
}
