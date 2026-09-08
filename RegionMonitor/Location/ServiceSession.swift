//
//  ServiceSession.swift
//  RegionMonitor
//
//  Holds the CLServiceSession (iOS 18+) that CoreLocation wants outstanding
//  while an app uses location, and logs the diagnostics it publishes.
//
//  This exists because of something a field log turned up: events delivered
//  after a background relaunch carried `serviceSessionRequired`, even though
//  this app does not adopt the `CLRequireExplicitServiceSession` Info.plist
//  key — the one condition the header says makes that flag true. Holding a
//  session settles it. Either the flag stops appearing, or it is reporting
//  something the header doesn't document, and the diagnostics stream below
//  will say which.
//
//  Note the Info.plist key is deliberately *not* adopted. It makes location
//  services conditional on a session being outstanding, which is a strictly
//  stronger promise than this app can keep across a background relaunch.
//

import CoreLocation
import Foundation

@available(iOS 18.0, *)
@MainActor
final class ServiceSession {

    static let shared = ServiceSession()

    private var session: CLServiceSession?
    private var requirement: CLServiceSession.AuthorizationRequirement?
    private var diagnosticsTask: Task<Void, Never>?

    private init() {}

    /// Opens a session matching the authorization actually granted, and
    /// replaces it if that grant changes. Idempotent — calling it with an
    /// unchanged status does nothing, so it is safe on every authorization
    /// callback.
    ///
    /// The requirement deliberately tracks what was granted rather than what
    /// the app wants. Asking for `.always` while holding only When In Use
    /// would put the session into a permanently denied state instead of
    /// working at the level available.
    func update(for status: CLAuthorizationStatus) {
        let wanted: CLServiceSession.AuthorizationRequirement?
        switch status {
        case .authorizedAlways:    wanted = .always
        case .authorizedWhenInUse: wanted = .whenInUse
        default:                   wanted = nil
        }

        guard wanted != requirement else { return }

        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        session?.invalidate()
        session = nil
        requirement = wanted

        guard let wanted else {
            LogWriter.shared.log(.note, detail: "No CLServiceSession \u{2014} location not authorized")
            return
        }

        let opened = CLServiceSession(authorization: wanted)
        session = opened
        LogWriter.shared.log(.note, detail: "CLServiceSession opened requiring \(wanted.label)")

        diagnosticsTask = Task { await Self.consume(opened.diagnostics) }
    }

    private static func consume(_ diagnostics: CLServiceSession.Diagnostics) async {
        do {
            for try await diagnostic in diagnostics {
                if let problems = flags(in: diagnostic) {
                    LogWriter.shared.log(.error, detail: "CLServiceSession suspended: \(problems)")
                } else {
                    LogWriter.shared.log(.note, detail: "CLServiceSession running, nothing reported")
                }
            }
        } catch is CancellationError {
            // Replaced by a session at a different authorization level.
        } catch {
            LogWriter.shared.log(.error, detail: "CLServiceSession diagnostics failed: \(error.localizedDescription)")
        }
    }

    /// Every reason CoreLocation gives for suspending the session. Returns nil
    /// when none are set, which is the healthy case.
    private static func flags(in diagnostic: CLServiceSession.Diagnostic) -> String? {
        let set = [
            ("authDenied", diagnostic.authorizationDenied),
            ("authDeniedGlobally", diagnostic.authorizationDeniedGlobally),
            ("authRestricted", diagnostic.authorizationRestricted),
            ("insufficientlyInUse", diagnostic.insufficientlyInUse),
            ("fullAccuracyDenied", diagnostic.fullAccuracyDenied),
            ("alwaysAuthorizationDenied", diagnostic.alwaysAuthorizationDenied),
            ("serviceSessionRequired", diagnostic.serviceSessionRequired),
            ("authRequestInProgress", diagnostic.authorizationRequestInProgress),
        ].filter(\.1).map(\.0)

        return set.isEmpty ? nil : set.joined(separator: ",")
    }
}

@available(iOS 18.0, *)
extension CLServiceSession.AuthorizationRequirement {
    var label: String {
        switch self {
        case .always:    return "always"
        case .whenInUse: return "whenInUse"
        case .none:      return "none"
        @unknown default: return "unknown"
        }
    }
}
