//
//  LegacyRegionMonitor.swift
//  RegionMonitor
//
//  Region monitoring for iOS 16, on CLCircularRegion and CLLocationManager.
//
//  CLMonitor does not exist before iOS 17, so there is no way to share a
//  backend across both. RegionMonitorEngine handles 17+; this handles 16.
//  LocationService picks between them at runtime and nothing else in the app
//  knows which is running.
//
//  The API here is soft-deprecated — the header marks it
//  `API_DEPRECATED_WITH_REPLACEMENT(..., ios(7.0, API_TO_BE_DEPRECATED))`, and
//  `API_TO_BE_DEPRECATED` is 100000, a version no deployment target reaches.
//  So it compiles without a warning and will keep working; it is simply the
//  only option on 16.
//
//  Log lines are deliberately formatted to match the CLMonitor path, down to
//  the `prev=` and `distToCentre=` fields, so logs from the two backends can
//  be compared line for line. Two fields differ, and say so:
//
//    * no `evt=`, because CLCircularRegion callbacks carry no event timestamp
//      of their own — the callback *is* the event.
//    * no `flags=`, which are CLMonitor's per-event diagnostics.
//
//  In exchange this path has something 17+ lost: `requestState(for:)` really
//  does ask CoreLocation to resolve a region on demand.
//

import CoreLocation
import Foundation

final class LegacyRegionMonitor {

    static let shared = LegacyRegionMonitor()

    /// Set by LocationService at bootstrap. Weak is wrong here — the manager is
    /// owned for the life of the process — but the reference is assigned rather
    /// than created so this type never competes for ownership of it.
    private weak var manager: CLLocationManager?

    /// Entry/exit preferences and geometry, keyed by identifier. Unlike the
    /// CLMonitor path this is only needed for logging: CLCircularRegion honours
    /// notifyOnEntry/notifyOnExit itself, so no direction filtering happens here.
    private var configs: [String: RegionSnapshot] = [:]
    private var configsLoaded = false

    /// Last state seen per identifier, so a log line can report what came
    /// before — the same `prev=` the CLMonitor path writes.
    private var lastStates: [String: CLRegionState] = [:]

    private init() {}

    func attach(to manager: CLLocationManager) {
        self.manager = manager
    }

    // MARK: - Lifecycle

    /// Reconciles monitored regions against the store. Idempotent, so it is
    /// safe on every launch and every foreground.
    func sync() {
        guard manager != nil else { return }

        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            LogWriter.shared.log(.error, detail: "Circular region monitoring unavailable on this device")
            return
        }

        // Back to main once the fetch returns: CLLocationManager wants a thread
        // with a live run loop.
        Task { @MainActor [weak self] in
            let snapshots = await RegionStore.shared.activeSnapshots()
            guard let self, let manager = self.manager else { return }

            // An identifier collision must not take the app down; nothing in
            // the store enforces uniqueness.
            self.configs = Dictionary(snapshots.map { ($0.identifier, $0) },
                                      uniquingKeysWith: { first, _ in first })
            self.configsLoaded = true

            for region in manager.monitoredRegions where self.configs[region.identifier] == nil {
                manager.stopMonitoring(for: region)
                self.lastStates[region.identifier] = nil
                LogWriter.shared.log(.monitoringStop, regionIdentifier: region.identifier,
                                     detail: "no longer in store")
            }

            let alreadyMonitored = Set(manager.monitoredRegions.map(\.identifier))

            for snapshot in self.configs.values.sorted(by: { $0.createdAt < $1.createdAt }) {
                guard !alreadyMonitored.contains(snapshot.identifier) else { continue }
                guard manager.monitoredRegions.count < LocationService.maxMonitoredRegions else {
                    LogWriter.shared.log(.monitoringFailed, regionIdentifier: snapshot.identifier,
                                         detail: "skipped — \(LocationService.maxMonitoredRegions) region limit reached")
                    continue
                }

                let radius = min(snapshot.radius, manager.maximumRegionMonitoringDistance)
                let region = CLCircularRegion(center: snapshot.coordinate,
                                              radius: radius,
                                              identifier: snapshot.identifier)
                region.notifyOnEntry = snapshot.notifyOnEntry
                region.notifyOnExit = snapshot.notifyOnExit

                manager.startMonitoring(for: region)

                LogWriter.shared.log(
                    .monitoringStart,
                    regionIdentifier: snapshot.identifier,
                    detail: String(format: "center=%.6f,%.6f radius=%.0fm entry=%@ exit=%@ backend=CLCircularRegion",
                                   snapshot.coordinate.latitude, snapshot.coordinate.longitude,
                                   radius,
                                   snapshot.notifyOnEntry ? "Y" : "N",
                                   snapshot.notifyOnExit ? "Y" : "N")
                )
            }

            LocationService.shared.updateMonitoredIdentifiers(Set(manager.monitoredRegions.map(\.identifier)))
        }
    }

    func remove(identifier: String) {
        guard let manager else { return }

        for region in manager.monitoredRegions where region.identifier == identifier {
            manager.stopMonitoring(for: region)
            LogWriter.shared.log(.monitoringStop, regionIdentifier: identifier, detail: "removed by user")
        }
        lastStates[identifier] = nil
        configs[identifier] = nil

        let live = Set(manager.monitoredRegions.map(\.identifier))
        Task { @MainActor in LocationService.shared.updateMonitoredIdentifiers(live) }
    }

    /// A real state request, not a replayed record. This is the one thing the
    /// CLMonitor path cannot do — results arrive in `didDetermineState`.
    func requestStates() {
        guard let manager, !manager.monitoredRegions.isEmpty else {
            LogWriter.shared.log(.note, detail: "No regions are being monitored")
            return
        }
        for region in manager.monitoredRegions {
            manager.requestState(for: region)
        }
    }

    // MARK: - Delegate callbacks, forwarded from LocationService

    func didEnter(_ region: CLRegion) {
        record(.regionEnter, region: region, state: .inside)
    }

    func didExit(_ region: CLRegion) {
        record(.regionExit, region: region, state: .outside)
    }

    func didDetermineState(_ state: CLRegionState, for region: CLRegion) {
        let fix = LocationService.shared.lastLocation
        let previous = lastStates[region.identifier]
        lastStates[region.identifier] = state

        Task { @MainActor in
        let snapshot = await self.config(for: region.identifier)
        var parts = ["state=\(state.legacyLabel)", "prev=\(previous?.legacyLabel ?? "none")"]
        if let distance = snapshot?.distanceDetail(from: fix) { parts.append(distance) }
        // CoreLocation calls didDetermineState both in answer to
        // requestState(for:) and unprompted, shortly after monitoring starts.
        // Claiming the former would be wrong half the time; what matters is
        // that either way it is a live determination, not a replayed record.
        parts.append("(fresh determination)")

        LogWriter.shared.log(.regionState,
                             location: fix,
                             regionIdentifier: region.identifier,
                             detail: parts.joined(separator: " "))
        }
    }

    func monitoringDidFail(for region: CLRegion?, error: Error) {
        LogWriter.shared.log(.monitoringFailed,
                             regionIdentifier: region?.identifier,
                             detail: error.localizedDescription)
    }

    // MARK: - Logging

    private func record(_ type: EventType, region: CLRegion, state: CLRegionState) {
        let fix = LocationService.shared.lastLocation
        let previous = lastStates[region.identifier]
        lastStates[region.identifier] = state

        Task { @MainActor in
            let snapshot = await self.config(for: region.identifier)

            var parts = ["state=\(state.legacyLabel)", "prev=\(previous?.legacyLabel ?? "none")"]
            let distance = snapshot?.distanceDetail(from: fix)
            if let distance { parts.append(distance) }
            if snapshot == nil { parts.append("no matching region in store") }

            LogWriter.shared.log(type,
                                 location: fix,
                                 regionIdentifier: region.identifier,
                                 detail: parts.joined(separator: " "))

            Notifier.shared.postCrossing(type,
                                         region: region.identifier,
                                         body: distance ?? "state=\(state.legacyLabel)")
        }
    }

    /// A crossing can arrive before the first `sync()` has filled the cache —
    /// on a background relaunch it usually does. Fall back to a lookup the
    /// first time an identifier is missing, so the log still gets its distance
    /// detail instead of "no matching region in store".
    private func config(for identifier: String) async -> RegionSnapshot? {
        if let snapshot = configs[identifier] { return snapshot }
        guard !configsLoaded else { return nil }

        let snapshots = await RegionStore.shared.activeSnapshots()
        configs = Dictionary(snapshots.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        configsLoaded = true
        return configs[identifier]
    }
}

// MARK: - Readable labels

/// Named to match the CLMonitor vocabulary rather than CoreLocation's older
/// one, so `prev=` and `state=` mean the same thing whichever backend wrote
/// the line: inside is satisfied, outside is unsatisfied.
extension CLRegionState {
    var legacyLabel: String {
        switch self {
        case .inside:     return "satisfied"
        case .outside:    return "unsatisfied"
        case .unknown:    return "unknown"
        @unknown default: return "unknown"
        }
    }
}
