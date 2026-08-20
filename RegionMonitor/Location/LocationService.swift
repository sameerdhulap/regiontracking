//
//  LocationService.swift
//  RegionMonitor
//
//  Owns the single CLLocationManager for the process. It must be created and
//  have its delegate wired up *synchronously* inside
//  didFinishLaunchingWithOptions — if the app is relaunched into the
//  background for a region crossing and the delegate isn't set by the time
//  that method returns, the event is dropped.
//

import CoreLocation
import Foundation
import UIKit

final class LocationService: NSObject, ObservableObject {

    static let shared = LocationService()

    /// iOS hard-caps a single app at 20 simultaneously monitored regions.
    static let maxMonitoredRegions = 20

    private let manager = CLLocationManager()

    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization = .reducedAccuracy
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var monitoredIdentifiers: Set<String> = []
    @Published var isStreamingContinuousUpdates = false

    /// When true, every enter/exit is followed by an explicit
    /// `requestState(for:)`. The system's own determination logged a beat
    /// later is the cheapest way to tell a real crossing from a jittery fix
    /// bouncing across the boundary.
    @Published var verifyStateAfterTransition = true {
        didSet { UserDefaults.standard.set(verifyStateAfterTransition, forKey: "verifyStateAfterTransition") }
    }

    private override init() {
        super.init()
        verifyStateAfterTransition = UserDefaults.standard.object(forKey: "verifyStateAfterTransition") as? Bool ?? true
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

    /// Re-registers regions from Core Data. Monitored regions do survive app
    /// termination, but they're silently dropped if the app is reinstalled or
    /// the OS evicts them, so reconciling on launch is cheap insurance.
    func syncRegions() {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            LogWriter.shared.log(.error, detail: "Circular region monitoring unavailable on this device")
            return
        }

        RegionStore.shared.fetchActive { [weak self] stored in
            guard let self else { return }

            let desired = Dictionary(uniqueKeysWithValues: stored.map { ($0.identifier, $0) })
            let current = self.manager.monitoredRegions

            // Drop anything the OS is tracking that we no longer care about.
            for region in current where desired[region.identifier] == nil {
                self.manager.stopMonitoring(for: region)
                LogWriter.shared.log(.monitoringStop, regionIdentifier: region.identifier,
                                     detail: "no longer in store")
            }

            let currentIDs = Set(current.map(\.identifier))

            for (identifier, snapshot) in desired {
                guard !currentIDs.contains(identifier) else { continue }
                guard self.manager.monitoredRegions.count < Self.maxMonitoredRegions else {
                    LogWriter.shared.log(.monitoringFailed, regionIdentifier: identifier,
                                         detail: "skipped — 20 region limit reached")
                    continue
                }

                let region = CLCircularRegion(center: snapshot.coordinate,
                                              radius: min(snapshot.radius, self.manager.maximumRegionMonitoringDistance),
                                              identifier: identifier)
                region.notifyOnEntry = snapshot.notifyOnEntry
                region.notifyOnExit = snapshot.notifyOnExit

                self.manager.startMonitoring(for: region)
                LogWriter.shared.log(
                    .monitoringStart,
                    regionIdentifier: identifier,
                    detail: String(format: "center=%.6f,%.6f radius=%.0fm entry=%@ exit=%@",
                                   snapshot.coordinate.latitude, snapshot.coordinate.longitude,
                                   region.radius,
                                   region.notifyOnEntry ? "Y" : "N",
                                   region.notifyOnExit ? "Y" : "N")
                )

                // Resolve inside/outside right away so the log has a known
                // starting state instead of an implicit one.
                self.manager.requestState(for: region)
            }

            self.monitoredIdentifiers = Set(self.manager.monitoredRegions.map(\.identifier))
        }
    }

    func stopMonitoring(identifier: String) {
        for region in manager.monitoredRegions where region.identifier == identifier {
            manager.stopMonitoring(for: region)
            LogWriter.shared.log(.monitoringStop, regionIdentifier: identifier, detail: "removed by user")
        }
        monitoredIdentifiers = Set(manager.monitoredRegions.map(\.identifier))
    }

    func requestStateForAll() {
        for region in manager.monitoredRegions {
            manager.requestState(for: region)
        }
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

        if status == .authorizedAlways || status == .authorizedWhenInUse {
            startMonitoringAll()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        DispatchQueue.main.async { self.lastLocation = latest }

        for location in locations {
            LogWriter.shared.log(.location, location: location,
                                 detail: String(format: "age=%.1fs", -location.timestamp.timeIntervalSinceNow))
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        LogWriter.shared.log(.regionEnter,
                             location: lastLocation,
                             regionIdentifier: region.identifier,
                             detail: distanceDetail(to: region))
        if verifyStateAfterTransition { manager.requestState(for: region) }
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        LogWriter.shared.log(.regionExit,
                             location: lastLocation,
                             regionIdentifier: region.identifier,
                             detail: distanceDetail(to: region))
        if verifyStateAfterTransition { manager.requestState(for: region) }
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        LogWriter.shared.log(.regionState,
                             location: lastLocation,
                             regionIdentifier: region.identifier,
                             detail: "state=\(state.label) \(distanceDetail(to: region) ?? "")")
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

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        LogWriter.shared.log(.monitoringFailed,
                             regionIdentifier: region?.identifier,
                             detail: error.localizedDescription)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient — CL will keep trying.
        if let clError = error as? CLError, clError.code == .locationUnknown { return }
        LogWriter.shared.log(.error, detail: error.localizedDescription)
    }

    /// Distance from the last known fix to the region centre, alongside that
    /// fix's accuracy. When those two numbers overlap, a transition is inside
    /// the noise floor rather than a real crossing.
    private func distanceDetail(to region: CLRegion) -> String? {
        guard let circular = region as? CLCircularRegion, let fix = lastLocation else { return nil }
        let centre = CLLocation(latitude: circular.center.latitude, longitude: circular.center.longitude)
        let distance = fix.distance(from: centre)
        let margin = distance - circular.radius
        return String(format: "distToCentre=%.0fm radius=%.0fm margin=%+.0fm hAcc=%.0fm",
                      distance, circular.radius, margin, fix.horizontalAccuracy)
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

extension CLRegionState {
    var label: String {
        switch self {
        case .inside:  return "inside"
        case .outside: return "outside"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }
}
