//
//  RegionMonitorEngine.swift
//  RegionMonitor
//
//  Region monitoring on top of CLMonitor / CLCircularGeographicCondition,
//  which replace the soft-deprecated CLCircularRegion path on
//  CLLocationManager.
//
//  Two properties of that API shape everything below:
//
//  1. Conditions live in a file CoreLocation keeps for us, named after the
//     monitor, inside the app's data container
//     (Library/CoreLocation/RegionMonitor/RegionMonitorConditions.monitor).
//     That file is protected, so the monitor cannot be opened before the
//     first unlock after boot.
//  2. Events arrive on an AsyncSequence rather than a delegate, and
//     CoreLocation *stops monitoring* a condition when an event is pending
//     for it and no CLMonitor has been opened to receive it. The consuming
//     task therefore has to start at launch and stay up for the life of the
//     process — same constraint the delegate had, different mechanism.
//

import CoreLocation
import Foundation
import UIKit

actor RegionMonitorEngine {

    static let shared = RegionMonitorEngine()

    /// Names the on-disk condition store. Changing it strands every condition
    /// already registered under the old name.
    ///
    /// Must be alphanumeric — CoreLocation throws
    /// `NSInternalInconsistencyException("Monitor name is not valid")` from the
    /// initialiser otherwise, which is not something the header mentions.
    private static let monitorName = "RegionMonitorConditions"

    private var monitor: CLMonitor?
    private var openTask: Task<CLMonitor, Never>?
    private var eventTask: Task<Void, Never>?

    /// Entry/exit preferences keyed by identifier. CLMonitor reports both
    /// directions unconditionally, so the filtering `notifyOnEntry` and
    /// `notifyOnExit` used to get from CLCircularRegion happens here now.
    private var configs: [String: RegionSnapshot] = [:]
    private var configsLoaded = false

    /// Last state seen per identifier, so each log line can say what the
    /// state was before. A `prev=unknown` is how an initial determination
    /// tells itself apart from a crossing — CLMonitor doesn't distinguish
    /// the two for us.
    private var lastStates: [String: CLMonitor.Event.State] = [:]

    private init() {}

    // MARK: - Lifecycle

    /// Opens the monitor and starts draining its events. Idempotent, and safe
    /// to call before authorization has been granted.
    func start() async {
        _ = await activeMonitor()
    }

    /// Reconciles the monitored conditions against the store. Safe to call on
    /// every launch and every foreground.
    func sync() async {
        let monitor = await activeMonitor()
        await reloadConfigs()

        let existing = Set(await monitor.identifiers)

        for identifier in existing where configs[identifier] == nil {
            await monitor.remove(identifier)
            lastStates[identifier] = nil
            LogWriter.shared.log(.monitoringStop, regionIdentifier: identifier,
                                 detail: "no longer in store")
        }

        var live = existing.intersection(configs.keys)
        let maximumRadius = LocationService.shared.maximumRegionRadius

        for snapshot in configs.values.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard !existing.contains(snapshot.identifier) else { continue }
            guard live.count < LocationService.maxMonitoredRegions else {
                LogWriter.shared.log(.monitoringFailed, regionIdentifier: snapshot.identifier,
                                     detail: "skipped — \(LocationService.maxMonitoredRegions) condition limit reached")
                continue
            }

            let radius = min(snapshot.radius, maximumRadius)
            let condition = CLMonitor.CircularGeographicCondition(center: snapshot.coordinate,
                                                                  radius: radius)
            await monitor.add(condition, identifier: snapshot.identifier, assuming: .unknown)
            live.insert(snapshot.identifier)

            LogWriter.shared.log(
                .monitoringStart,
                regionIdentifier: snapshot.identifier,
                detail: String(format: "center=%.6f,%.6f radius=%.0fm entry=%@ exit=%@",
                               snapshot.coordinate.latitude, snapshot.coordinate.longitude,
                               radius,
                               snapshot.notifyOnEntry ? "Y" : "N",
                               snapshot.notifyOnExit ? "Y" : "N")
            )
        }

        // Pick up whatever CoreLocation already resolved for conditions that
        // outlived a previous launch, so the first event after relaunch can
        // still report a meaningful `prev=`.
        for identifier in live where lastStates[identifier] == nil {
            if let record = await monitor.record(for: identifier) {
                lastStates[identifier] = record.lastEvent.state
            }
        }

        await publish(identifiers: Set(await monitor.identifiers))
    }

    func remove(identifier: String) async {
        let monitor = await activeMonitor()
        await monitor.remove(identifier)
        lastStates[identifier] = nil
        configs[identifier] = nil
        LogWriter.shared.log(.monitoringStop, regionIdentifier: identifier, detail: "removed by user")
        await publish(identifiers: Set(await monitor.identifiers))
    }

    /// Logs the state CoreLocation currently holds for every monitored
    /// condition.
    ///
    /// This is *not* the old `requestState(for:)` — that asked CoreLocation to
    /// go and resolve the region there and then. CLMonitor has no equivalent;
    /// all we can read back is the last event it persisted, so a line logged
    /// here can be arbitrarily old. `date=` says how old.
    func logCurrentStates() async {
        let monitor = await activeMonitor()
        let identifiers = await monitor.identifiers

        guard !identifiers.isEmpty else {
            LogWriter.shared.log(.note, detail: "No conditions are being monitored")
            return
        }

        for identifier in identifiers {
            guard let record = await monitor.record(for: identifier) else {
                LogWriter.shared.log(.regionState, regionIdentifier: identifier,
                                     detail: "no record held by CoreLocation")
                continue
            }
            let event = record.lastEvent
            LogWriter.shared.log(
                .regionState,
                location: await currentFix(),
                regionIdentifier: identifier,
                detail: "state=\(event.state.label) date=\(Self.timestamp.string(from: event.date)) (persisted record, not a fresh fix)"
            )
        }
    }

    // MARK: - Opening the monitor

    private func activeMonitor() async -> CLMonitor {
        if let monitor { return monitor }

        // Memoised so two concurrent callers can't try to open the same name
        // twice — CoreLocation allows only one open monitor per name.
        if let openTask { return await openTask.value }

        let task = Task { () -> CLMonitor in
            await Self.waitForProtectedData()
            return await CLMonitor(Self.monitorName)
        }
        openTask = task
        let opened = await task.value
        openTask = nil

        // The actor can suspend above, so a second caller may have finished
        // first. Keep whichever instance was installed.
        if let monitor { return monitor }

        monitor = opened
        eventTask = Task { [weak self] in await self?.consumeEvents(from: opened) }
        return opened
    }

    /// The condition store lives in the data container, so it can't be opened
    /// until the device has been unlocked once since boot.
    private static func waitForProtectedData() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                // The check and the registration both run here without an
                // await between them, so the notification can't slip through
                // the gap.
                if UIApplication.shared.isProtectedDataAvailable {
                    continuation.resume()
                    return
                }

                LogWriter.shared.log(.note, detail: "Waiting for first unlock before opening the condition store")

                let box = ObserverBox()
                box.token = NotificationCenter.default.addObserver(
                    forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                    object: nil,
                    queue: .main
                ) { _ in
                    box.release()
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Events

    private func consumeEvents(from monitor: CLMonitor) async {
        do {
            for try await event in await monitor.events {
                await handle(event)
            }
            LogWriter.shared.log(.error, detail: "CLMonitor event stream ended — no further region events will be logged")
        } catch {
            LogWriter.shared.log(.error, detail: "CLMonitor event stream failed: \(error.localizedDescription)")
        }
    }

    private func handle(_ event: CLMonitor.Event) async {
        let identifier = event.identifier
        let previous = lastStates[identifier]
        lastStates[identifier] = event.state

        let snapshot = await config(for: identifier)
        let fix = await currentFix()

        var type: EventType
        switch event.state {
        case .satisfied:   type = .regionEnter
        case .unsatisfied: type = .regionExit
        case .unknown:     type = .regionState
        default:           type = .monitoringStop   // .unmonitored, iOS 17.2+
        }

        // CLCircularRegion used to suppress the unwanted direction for us.
        // Downgrade rather than drop it: this app exists to show what
        // CoreLocation actually reported.
        var suppressed: String?
        if let snapshot {
            if type == .regionEnter, !snapshot.notifyOnEntry { suppressed = "entry"; type = .regionState }
            if type == .regionExit, !snapshot.notifyOnExit { suppressed = "exit"; type = .regionState }
        }

        var parts = ["state=\(event.state.label)", "prev=\(previous?.label ?? "none")"]
        if let suppressed { parts.append("suppressed=\(suppressed)") }
        parts.append("eventAge=\(String(format: "%.1fs", -event.date.timeIntervalSinceNow))")
        if let snapshot, let distance = Self.distanceDetail(from: fix, to: snapshot) { parts.append(distance) }
        if snapshot == nil { parts.append("no matching region in store") }
        if event.refinement != nil { parts.append("refined=Y") }
        if let flags = Self.diagnosticFlags(for: event) { parts.append("flags=\(flags)") }

        LogWriter.shared.log(type,
                             location: fix,
                             regionIdentifier: identifier,
                             detail: parts.joined(separator: " "))
    }

    /// iOS 18 added per-event reasons for a condition not being monitored.
    /// They're the only way to see an authorization or limit problem now that
    /// there's no `monitoringDidFailFor` delegate callback.
    private static func diagnosticFlags(for event: CLMonitor.Event) -> String? {
        guard #available(iOS 18.0, *) else { return nil }

        let flags = [
            ("authDenied", event.authorizationDenied),
            ("authDeniedGlobally", event.authorizationDeniedGlobally),
            ("authRestricted", event.authorizationRestricted),
            ("insufficientlyInUse", event.insufficientlyInUse),
            ("accuracyLimited", event.accuracyLimited),
            ("conditionUnsupported", event.conditionUnsupported),
            ("conditionLimitExceeded", event.conditionLimitExceeded),
            ("persistenceUnavailable", event.persistenceUnavailable),
            ("serviceSessionRequired", event.serviceSessionRequired),
            ("authRequestInProgress", event.authorizationRequestInProgress),
        ].filter(\.1).map(\.0)

        return flags.isEmpty ? nil : flags.joined(separator: ",")
    }

    /// Distance from the last known fix to the condition centre, alongside
    /// that fix's accuracy. When those two numbers overlap, a transition is
    /// inside the noise floor rather than a real crossing.
    private static func distanceDetail(from fix: CLLocation?, to snapshot: RegionSnapshot) -> String? {
        guard let fix else { return nil }
        let centre = CLLocation(latitude: snapshot.coordinate.latitude,
                                longitude: snapshot.coordinate.longitude)
        let distance = fix.distance(from: centre)
        return String(format: "distToCentre=%.0fm radius=%.0fm margin=%+.0fm hAcc=%.0fm",
                      distance, snapshot.radius, distance - snapshot.radius, fix.horizontalAccuracy)
    }

    // MARK: - Store

    private func reloadConfigs() async {
        let snapshots = await RegionStore.shared.activeSnapshots()
        // Nothing stops the user creating two regions with the same name, and
        // an identifier collision must not take the app down.
        configs = Dictionary(snapshots.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        configsLoaded = true
    }

    /// An event can land before the first `sync()`, so fall back to a lookup
    /// the first time an identifier isn't in the cache.
    private func config(for identifier: String) async -> RegionSnapshot? {
        if let snapshot = configs[identifier] { return snapshot }
        guard !configsLoaded else { return nil }
        await reloadConfigs()
        return configs[identifier]
    }

    private func currentFix() async -> CLLocation? {
        await MainActor.run { LocationService.shared.lastLocation }
    }

    private func publish(identifiers: Set<String>) async {
        await MainActor.run { LocationService.shared.updateMonitoredIdentifiers(identifiers) }
    }

    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/// Lets the unlock observer deregister itself from inside its own handler.
/// Only ever touched on the main queue — the queue the observer is registered
/// against, and the one that installs the token.
private final class ObserverBox: @unchecked Sendable {
    var token: NSObjectProtocol?
    func release() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}

// MARK: - Readable labels

extension CLMonitor.Event.State {
    var label: String {
        switch self {
        case .unknown:     return "unknown"
        case .satisfied:   return "satisfied"
        case .unsatisfied: return "unsatisfied"
        default:           return "unmonitored"   // iOS 17.2+
        }
    }
}
